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

/// A frame sink for captured audio (mic or system) — UI level meters etc.
protocol FrameEmitting: AnyObject {
  func emit(samples: [Float])
}

/// Fans a 16 kHz mono capture stream out to attached sessions, strictly in
/// order. Shared by microphone and system-audio capture.
final class AudioFanout {
  struct Attachments {
    let asr: [StreamingAsrInstance]
    let eou: [EouInstance]
    let vad: [(id: Int64, instance: VadStreamInstance)]
    let emitFrames: Bool
  }

  private let attachments: Attachments
  private let chunkers: [SampleChunker]
  private let frames: FrameEmitting
  private let vadEvents: VadEventsHandler

  /// Optional WAV tee. Lives on the fan-out so it survives the system-audio
  /// watchdog's chain rebuild; only [closeWav] (from a real capture stop)
  /// finalizes the file.
  private let wav: WavSink?

  /// Watchdog counters: written from the serial dispatch context, read from
  /// the watchdog task.
  private let stats = OSAllocatedUnfairLock(initialState: (callbacks: 0, nonZeroFrames: 0))

  init(
    attachments: Attachments, frames: FrameEmitting, vadEvents: VadEventsHandler,
    wav: WavSink? = nil
  ) {
    self.attachments = attachments
    self.chunkers = attachments.vad.map { _ in SampleChunker(chunkSize: VadManager.chunkSize) }
    self.frames = frames
    self.vadEvents = vadEvents
    self.wav = wav
  }

  /// Finalizes the WAV tee, if any. Idempotent.
  func closeWav() {
    wav?.close()
  }

  var snapshot: (callbacks: Int, nonZeroFrames: Int) {
    stats.withLock { $0 }
  }

  func resetStats() {
    stats.withLock { $0 = (callbacks: 0, nonZeroFrames: 0) }
  }

  /// Must be called from a single serial context to preserve feed order.
  func dispatch(_ samples: [Float]) {
    let nonZero = samples.contains { $0 != 0 } ? 1 : 0
    stats.withLock {
      $0.callbacks += 1
      $0.nonZeroFrames += nonZero
    }
    // File first, consumers after: recording completeness never depends on
    // downstream sessions keeping up (the reference recorder's contract).
    wav?.write(samples)
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

/// Streams capture watchdog phase transitions for mic and system audio.
final class CaptureHealthHandler: CaptureHealthStreamHandler {
  private var sink: PigeonEventSink<CaptureHealthMessage>?

  override func onListen(
    withArguments arguments: Any?, sink: PigeonEventSink<CaptureHealthMessage>
  ) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(
    source: CaptureSourceMessage,
    phase: CaptureHealthPhaseMessage,
    callbackCount: Int,
    receivingAudio: Bool,
    detail: String? = nil
  ) {
    let message = CaptureHealthMessage(
      source: source, phase: phase, callbackCount: Int64(callbackCount),
      receivingAudio: receivingAudio, detail: detail)
    if Thread.isMainThread {
      sink?.success(message)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(message) }
    }
  }
}

/// Streams captured mic frames (16 kHz mono) for UI level meters/waveforms.
final class MicFramesHandler: MicFramesStreamHandler, FrameEmitting {
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
  typealias Attachments = AudioFanout.Attachments

  private let engine = AVAudioEngine()
  private let queue = SerialTaskQueue()
  private var watchdogTask: Task<Void, Never>?
  private var fanout: AudioFanout?

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
    vadEvents: VadEventsHandler,
    health: CaptureHealthHandler,
    wavSink: WavSink? = nil
  ) throws {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
      try session.setActive(true)
    #endif

    let fanout = AudioFanout(
      attachments: attachments, frames: frames, vadEvents: vadEvents, wav: wavSink)
    self.fanout = fanout
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // One converter per session: resampler filter state must carry across
    // buffers (a fresh converter per buffer causes boundary artifacts). Only
    // touched from the serial queue.
    guard let resampler = PersistentResampler(from: format) else {
      throw PigeonError(
        code: "ConverterUnavailable",
        message: "Could not build a converter for the input format \(format)", details: nil)
    }

    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      guard let self, self.running else { return }
      // Real-time audio thread: deep-copy only, then hop to the serial queue.
      guard let copy = Self.copyBuffer(buffer) else { return }
      self.queue.enqueue {
        guard let samples = resampler.resample(copy), !samples.isEmpty else { return }
        fanout.dispatch(samples)
      }
    }

    engine.prepare()
    try engine.start()
    runningState.withLock { $0 = true }

    // Self-test: a healthy mic always shows noise-floor non-zero samples
    // within the window; all-zero frames indicate a broken/muted capture.
    // Informational only — no rebuild for the microphone.
    health.emit(
      source: .microphone, phase: .validating, callbackCount: 0, receivingAudio: false)
    watchdogTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard let self, self.running else { return }
      let snapshot = fanout.snapshot
      // Re-check after the snapshot read: a concurrent stop() between the
      // guard above and here must not produce a stale health emission.
      guard self.running else { return }
      if snapshot.nonZeroFrames > 0 {
        health.emit(
          source: .microphone, phase: .healthy, callbackCount: snapshot.callbacks,
          receivingAudio: true)
      } else {
        health.emit(
          source: .microphone, phase: .silent, callbackCount: snapshot.callbacks,
          receivingAudio: false,
          detail: snapshot.callbacks == 0
            ? "no capture callbacks in 2s — the input device may be unavailable"
            : "callbacks firing but every frame is zero — mic muted or capture broken")
      }
    }
  }

  func stop() {
    let wasRunning = runningState.withLock { state in
      let previous = state
      state = false
      return previous
    }
    guard wasRunning else { return }
    watchdogTask?.cancel()
    watchdogTask = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    queue.shutdown()
    // After the queue is down no more dispatches start; the sink's own lock
    // covers any straggler already mid-dispatch.
    fanout?.closeWav()
    fanout = nil
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
  private let health: CaptureHealthHandler
  private var capture: MicCapture?

  init(
    registry: InstanceRegistry, frames: MicFramesHandler, vadEvents: VadEventsHandler,
    health: CaptureHealthHandler
  ) {
    self.registry = registry
    self.frames = frames
    self.vadEvents = vadEvents
    self.health = health
  }

  func start(
    asrInstanceIds: [Int64], eouInstanceIds: [Int64], vadStreamIds: [Int64], emitFrames: Bool,
    recordToWavPath: String?,
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
    var wavSink: WavSink?
    do {
      // An unwritable path fails the start loudly — the caller asked for a
      // recording, so a silent no-record would be worse than an error.
      wavSink = try recordToWavPath.map { try WavSink(path: $0) }
      try newCapture.start(
        attachments: MicCapture.Attachments(
          asr: asr, eou: eou, vad: vad, emitFrames: emitFrames),
        frames: frames,
        vadEvents: vadEvents,
        health: health,
        wavSink: wavSink
      )
      capture = newCapture
      completion(.success(()))
    } catch {
      wavSink?.close()
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
