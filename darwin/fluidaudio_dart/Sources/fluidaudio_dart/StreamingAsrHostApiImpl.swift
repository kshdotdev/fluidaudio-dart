import AVFoundation
import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// A live sliding-window streaming session.
///
/// All audio and lifecycle operations funnel through `queue` so they reach the
/// actor strictly in call order — concurrent feeding reorders decoding.
final class StreamingAsrInstance {
  let manager: SlidingWindowAsrManager
  let queue = SerialTaskQueue()
  var updatesTask: Task<Void, Never>?

  init(manager: SlidingWindowAsrManager) {
    self.manager = manager
  }

  func shutdown() {
    updatesTask?.cancel()
    queue.shutdown()
  }
}

final class StreamingAsrHostApiImpl: StreamingAsrHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler
  private let updates: TranscriptionUpdatesHandler

  init(
    registry: InstanceRegistry,
    downloadProgress: DownloadProgressHandler,
    updates: TranscriptionUpdatesHandler
  ) {
    self.registry = registry
    self.downloadProgress = downloadProgress
    self.updates = updates
  }

  private static func config(from message: StreamingConfigMessage?) -> SlidingWindowAsrConfig {
    guard let message else { return .streaming }
    // Defaults mirror the `.streaming` preset.
    return SlidingWindowAsrConfig(
      chunkSeconds: message.chunkSeconds ?? 11.0,
      hypothesisChunkSeconds: message.hypothesisChunkSeconds ?? 1.0,
      leftContextSeconds: message.leftContextSeconds ?? 2.0,
      rightContextSeconds: message.rightContextSeconds ?? 2.0,
      minContextForConfirmation: message.minContextForConfirmation ?? 10.0,
      confirmationThreshold: message.confirmationThreshold ?? 0.80
    )
  }

  func create(
    version: AsrVersionMessage, config: StreamingConfigMessage?, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let modelVersion: AsrModelVersion = version == .v2 ? .v2 : .v3
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        let models = try await AsrModels.downloadAndLoad(
          version: modelVersion, progressHandler: handler)
        let manager = SlidingWindowAsrManager(config: Self.config(from: config))
        try await manager.loadModels(models)
        let instance = StreamingAsrInstance(manager: manager)
        let id = self.registry.add(instance)
        // Subscribe BEFORE startStreaming so no update is dropped (ectos rule).
        instance.updatesTask = Task { [weak self] in
          let stream = await manager.transcriptionUpdates
          for await update in stream {
            self?.updates.emit(instanceId: id, update: update)
          }
        }
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  private func instance<T>(
    _ id: Int64, orFail completion: @escaping (Result<T, Error>) -> Void
  ) -> StreamingAsrInstance? {
    guard let instance = registry.get(id, as: StreamingAsrInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(id, kind: "streaming ASR")))
      return nil
    }
    return instance
  }

  func start(
    instanceId: Int64, source: AudioSourceMessage,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let instance = instance(instanceId, orFail: completion) else { return }
    let audioSource: AudioSource = source == .system ? .system : .microphone
    let manager = instance.manager
    instance.queue.enqueue {
      do {
        try await manager.startStreaming(source: audioSource)
        completion(.success(()))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func feed(
    instanceId: Int64, float32Samples: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let instance = instance(instanceId, orFail: completion) else { return }
    let samples = AudioBridge.floats(from: float32Samples)
    guard let buffer = AudioBridge.pcmBuffer(from: samples) else {
      completion(
        .failure(
          PigeonError(
            code: "InvalidAudio", message: "Could not create PCM buffer", details: nil)))
      return
    }
    let manager = instance.manager
    instance.queue.enqueue {
      await manager.streamAudio(buffer)
    }
    // Fire-and-forget: ordering is guaranteed by the serial queue; completing
    // immediately keeps the channel free for the next chunk.
    completion(.success(()))
  }

  func configureVocabulary(
    instanceId: Int64, vocabularyId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let instance = instance(instanceId, orFail: completion) else { return }
    guard let vocabulary = registry.get(vocabularyId, as: CtcVocabularyInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(vocabularyId, kind: "CTC vocabulary")))
      return
    }
    let manager = instance.manager
    instance.queue.enqueue {
      do {
        try await manager.configureVocabularyBoosting(
          vocabulary: vocabulary.context, ctcModels: vocabulary.models)
        completion(.success(()))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func finish(instanceId: Int64, completion: @escaping (Result<String, Error>) -> Void) {
    guard let instance = instance(instanceId, orFail: completion) else { return }
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
    guard let instance = instance(instanceId, orFail: completion) else { return }
    let manager = instance.manager
    instance.queue.enqueue {
      do {
        try await manager.reset()
        completion(.success(()))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let instance = registry.remove(instanceId) as? StreamingAsrInstance else {
      completion(.success(()))
      return
    }
    let manager = instance.manager
    instance.queue.enqueue {
      await manager.cleanup()
      instance.shutdown()
      completion(.success(()))
    }
  }
}
