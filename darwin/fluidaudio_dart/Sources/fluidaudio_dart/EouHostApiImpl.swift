import AVFoundation
import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class EouInstance {
  let manager: StreamingEouAsrManager
  let queue = SerialTaskQueue()

  init(manager: StreamingEouAsrManager) {
    self.manager = manager
  }
}

/// Streams EOU partial transcripts and utterance-end events.
final class EouEventsHandler: EouEventsStreamHandler {
  private var sink: PigeonEventSink<EouEventMessage>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<EouEventMessage>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(instanceId: Int64, isUtteranceEnd: Bool, text: String) {
    let message = EouEventMessage(
      instanceId: instanceId, isUtteranceEnd: isUtteranceEnd, text: text)
    if Thread.isMainThread {
      sink?.success(message)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(message) }
    }
  }
}

final class EouHostApiImpl: EouHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler
  private let events: EouEventsHandler

  init(
    registry: InstanceRegistry,
    downloadProgress: DownloadProgressHandler,
    events: EouEventsHandler
  ) {
    self.registry = registry
    self.downloadProgress = downloadProgress
    self.events = events
  }

  private static func chunkSize(for message: EouChunkSizeMessage) -> StreamingChunkSize {
    switch message {
    case .ms160: return .ms160
    case .ms320: return .ms320
    case .ms1280: return .ms1280
    }
  }

  func create(
    chunkSize: EouChunkSizeMessage, eouDebounceMs: Int64, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let handler = downloadProgress.progressHandler(for: progressToken)
    let events = self.events
    Task {
      do {
        let manager = StreamingEouAsrManager(
          chunkSize: Self.chunkSize(for: chunkSize), eouDebounceMs: Int(eouDebounceMs))
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: handler)

        let instance = EouInstance(manager: manager)
        let id = self.registry.add(instance)
        await manager.setPartialCallback { text in
          events.emit(instanceId: id, isUtteranceEnd: false, text: text)
        }
        await manager.setEouCallback { text in
          events.emit(instanceId: id, isUtteranceEnd: true, text: text)
        }

        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func feed(
    instanceId: Int64, float32Samples: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: EouInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "EOU")))
      return
    }
    let samples = AudioBridge.floats(from: float32Samples)
    guard let buffer = AudioBridge.pcmBuffer(from: samples) else {
      completion(
        .failure(
          PigeonError(code: "InvalidAudio", message: "Could not create PCM buffer", details: nil)))
      return
    }
    let manager = instance.manager
    instance.queue.enqueue {
      // The returned string is always empty; transcripts arrive via callbacks.
      _ = try? await manager.process(audioBuffer: buffer)
    }
    completion(.success(()))
  }

  func finish(instanceId: Int64, completion: @escaping (Result<String, Error>) -> Void) {
    guard let instance = registry.get(instanceId, as: EouInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "EOU")))
      return
    }
    let manager = instance.manager
    instance.queue.enqueue {
      do {
        let transcript = try await manager.finish()
        completion(.success(transcript))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func reset(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let instance = registry.get(instanceId, as: EouInstance.self) else {
      completion(.success(()))
      return
    }
    let manager = instance.manager
    instance.queue.enqueue {
      await manager.reset()
      completion(.success(()))
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let instance = registry.remove(instanceId) as? EouInstance else {
      completion(.success(()))
      return
    }
    let manager = instance.manager
    instance.queue.enqueue {
      await manager.cleanup()
      instance.queue.shutdown()
      completion(.success(()))
    }
  }
}
