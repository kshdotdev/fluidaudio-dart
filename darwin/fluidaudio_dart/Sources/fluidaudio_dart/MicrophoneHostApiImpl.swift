import AVFoundation
import FluidAudio
import Foundation
import os

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Accumulates arbitrary-size sample batches and yields exact-size chunks
/// (the VAD model requires exactly 4096-sample inputs).
final class SampleChunker {
  private var buffer: [Float] = []
  let chunkSize: Int

  init(chunkSize: Int) {
    self.chunkSize = chunkSize
  }

  func push(_ samples: [Float]) -> [[Float]] {
    buffer.append(contentsOf: samples)
    var chunks: [[Float]] = []
    while buffer.count >= chunkSize {
      chunks.append(Array(buffer.prefix(chunkSize)))
      buffer.removeFirst(chunkSize)
    }
    return chunks
  }

  func reset() {
    buffer.removeAll()
  }
}

/// Streams captured mic frames (16 kHz mono) for UI level meters/waveforms.
final class MicFramesHandler: MicFramesStreamHandler {
  private var sink: PigeonEventSink<MicFrameMessage>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<MicFrameMessage>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(samples: [Float]) {
    guard !samples.isEmpty else { return }
    let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    let rms = Double((sumOfSquares / Float(samples.count)).squareRoot())
    let message = MicFrameMessage(samples: AudioBridge.typedData(from: samples), rms: rms)
    // `sink` is only touched on the main thread (onListen/onCancel run there),
    // so the emptiness check must also happen there — never on the caller's
    // background queue.
    if Thread.isMainThread {
      sink?.success(message)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(message) }
    }
  }
}

/// One live microphone capture: AVAudioEngine tap → resample to 16 kHz mono →
/// fan out natively to attached sessions. Audio never crosses the channel.
final class MicCapture {
  struct Attachments {
    let asr: [StreamingAsrInstance]
    let eou: [EouInstance]
    let vad: [(id: Int64, instance: VadStreamInstance)]
    let emitFrames: Bool
  }

  private let engine = AVAudioEngine()
  private let queue = SerialTaskQueue()
  private let converter = AudioConverter()

  /// Read on the real-time audio thread, written from the platform thread —
  /// must be lock-protected (plain Bool access across threads is a data race).
  private let runningState = OSAllocatedUnfairLock(initialState: false)

  var running: Bool {
    runningState.withLock { $0 }
  }

  deinit {
    // Belt-and-braces: never leave a hot microphone behind if the capture
    // object is dropped without an explicit stop().
    stop()
  }

  func start(
    attachments: Attachments,
    frames: MicFramesHandler,
    vadEvents: VadEventsHandler
  ) throws {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try session.setActive(true)
    #endif

    let chunkers = attachments.vad.map { _ in SampleChunker(chunkSize: VadManager.chunkSize) }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)

    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      guard let self, self.running else { return }
      // Real-time audio thread: deep-copy only, then hop to the serial queue.
      guard let copy = Self.copyBuffer(buffer) else { return }
      self.queue.enqueue { [converter = self.converter] in
        guard let samples = try? converter.resampleBuffer(copy) else { return }
        if attachments.emitFrames {
          frames.emit(samples: samples)
        }
        if !attachments.asr.isEmpty || !attachments.eou.isEmpty {
          guard let pcm = AudioBridge.pcmBuffer(from: samples) else { return }
          for instance in attachments.asr {
            let manager = instance.manager
            instance.queue.enqueue { await manager.streamAudio(pcm) }
          }
          for instance in attachments.eou {
            let manager = instance.manager
            instance.queue.enqueue { _ = try? await manager.process(audioBuffer: pcm) }
          }
        }
        for (index, attachment) in attachments.vad.enumerated() {
          for chunk in chunkers[index].push(samples) {
            attachment.instance.feedChunk(chunk, streamId: attachment.id, events: vadEvents)
          }
        }
      }
    }

    engine.prepare()
    try engine.start()
    runningState.withLock { $0 = true }
  }

  func stop() {
    let wasRunning = runningState.withLock { state in
      let previous = state
      state = false
      return previous
    }
    guard wasRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    queue.shutdown()
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    #endif
  }

  private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
      let source = buffer.floatChannelData,
      let destination = copy.floatChannelData
    else {
      return nil
    }
    copy.frameLength = buffer.frameLength
    for channel in 0..<Int(buffer.format.channelCount) {
      destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
    }
    return copy
  }
}

final class MicrophoneHostApiImpl: MicrophoneHostApi {
  private let registry: InstanceRegistry
  private let frames: MicFramesHandler
  private let vadEvents: VadEventsHandler
  private var capture: MicCapture?

  init(registry: InstanceRegistry, frames: MicFramesHandler, vadEvents: VadEventsHandler) {
    self.registry = registry
    self.frames = frames
    self.vadEvents = vadEvents
  }

  func start(
    asrInstanceIds: [Int64], eouInstanceIds: [Int64], vadStreamIds: [Int64], emitFrames: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    if capture?.running == true {
      completion(
        .failure(
          PigeonError(
            code: "MicAlreadyRunning", message: "Microphone capture is already running",
            details: nil)))
      return
    }

    var asr: [StreamingAsrInstance] = []
    for id in asrInstanceIds {
      guard let instance = registry.get(id, as: StreamingAsrInstance.self) else {
        completion(.failure(ErrorMapping.instanceNotFound(id, kind: "streaming ASR")))
        return
      }
      asr.append(instance)
    }
    var eou: [EouInstance] = []
    for id in eouInstanceIds {
      guard let instance = registry.get(id, as: EouInstance.self) else {
        completion(.failure(ErrorMapping.instanceNotFound(id, kind: "EOU")))
        return
      }
      eou.append(instance)
    }
    var vad: [(id: Int64, instance: VadStreamInstance)] = []
    for id in vadStreamIds {
      guard let instance = registry.get(id, as: VadStreamInstance.self) else {
        completion(.failure(ErrorMapping.instanceNotFound(id, kind: "VAD stream")))
        return
      }
      vad.append((id: id, instance: instance))
    }

    let newCapture = MicCapture()
    do {
      try newCapture.start(
        attachments: MicCapture.Attachments(
          asr: asr, eou: eou, vad: vad, emitFrames: emitFrames),
        frames: frames,
        vadEvents: vadEvents
      )
      capture = newCapture
      completion(.success(()))
    } catch {
      completion(.failure(ErrorMapping.map(error)))
    }
  }

  func stop(completion: @escaping (Result<Void, Error>) -> Void) {
    capture?.stop()
    capture = nil
    completion(.success(()))
  }

  /// Stops any live capture; used by plugin teardown (engine detach or
  /// re-registration), where no channel call will ever arrive.
  func teardown() {
    capture?.stop()
    capture = nil
  }

  func isRunning(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(capture?.running == true))
  }
}
