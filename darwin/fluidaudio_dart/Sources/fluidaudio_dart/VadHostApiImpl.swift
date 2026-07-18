import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class VadInstance {
  let manager: VadManager

  init(manager: VadManager) {
    self.manager = manager
  }
}

/// A VAD streaming session: caller-held state advanced strictly in feed order
/// through its serial queue.
final class VadStreamInstance {
  let vad: VadInstance
  let config: VadSegmentationConfig
  let queue = SerialTaskQueue()
  var state: VadStreamState

  init(vad: VadInstance, config: VadSegmentationConfig) {
    self.vad = vad
    self.config = config
    self.state = VadStreamState.initial()
  }

  /// Processes one exact-size chunk on the serial queue and emits the result.
  /// Shared by the channel feed path and native mic capture.
  func feedChunk(_ chunk: [Float], streamId: Int64, events: VadEventsHandler) {
    queue.enqueue { [self] in
      do {
        let result = try await vad.manager.processStreamingChunk(
          chunk, state: state, config: config, returnSeconds: true)
        state = result.state
        events.emit(streamId: streamId, result: result)
      } catch {
        NSLog("fluidaudio_dart VAD stream error: \(error)")
      }
    }
  }
}

final class VadHostApiImpl: VadHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler
  private let events: VadEventsHandler

  init(
    registry: InstanceRegistry,
    downloadProgress: DownloadProgressHandler,
    events: VadEventsHandler
  ) {
    self.registry = registry
    self.downloadProgress = downloadProgress
    self.events = events
  }

  func create(
    threshold: Double, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        let manager = try await VadManager(
          config: VadConfig(defaultThreshold: Float(threshold)),
          progressHandler: handler
        )
        let id = self.registry.add(VadInstance(manager: manager))
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func processSamples(
    instanceId: Int64, float32Samples: FlutterStandardTypedData,
    completion: @escaping (Result<[VadResultMessage], Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: VadInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "VAD")))
      return
    }
    let samples = AudioBridge.floats(from: float32Samples)
    Task {
      do {
        let results = try await instance.manager.process(samples)
        completion(
          .success(
            results.map {
              VadResultMessage(
                probability: Double($0.probability),
                isVoiceActive: $0.isVoiceActive,
                processingSeconds: $0.processingTime
              )
            }))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func createStream(
    instanceId: Int64, minSpeechDuration: Double?, minSilenceDuration: Double?,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: VadInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "VAD")))
      return
    }
    var config = VadSegmentationConfig.default
    if let minSpeechDuration {
      config.minSpeechDuration = minSpeechDuration
    }
    if let minSilenceDuration {
      config.minSilenceDuration = minSilenceDuration
    }
    let stream = VadStreamInstance(vad: instance, config: config)
    completion(.success(registry.add(stream)))
  }

  func feedStream(
    streamId: Int64, float32Chunk: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let stream = registry.get(streamId, as: VadStreamInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(streamId, kind: "VAD stream")))
      return
    }
    stream.feedChunk(AudioBridge.floats(from: float32Chunk), streamId: streamId, events: events)
    completion(.success(()))
  }

  func resetStream(streamId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let stream = registry.get(streamId, as: VadStreamInstance.self) else {
      completion(.success(()))
      return
    }
    stream.queue.enqueue {
      stream.state = VadStreamState.initial()
    }
    completion(.success(()))
  }

  func disposeStream(streamId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    if let stream = registry.remove(streamId) as? VadStreamInstance {
      stream.queue.shutdown()
    }
    completion(.success(()))
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    registry.remove(instanceId)
    completion(.success(()))
  }
}
