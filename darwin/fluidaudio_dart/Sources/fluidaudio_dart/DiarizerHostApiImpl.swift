import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class DiarizerInstance {
  let manager: OfflineDiarizerManager
  let operations = InferenceOperationStore(operationKind: "diarization")
  private let shutdownLock = NSLock()
  private var shutdownTask: Task<Void, Never>?

  init(manager: OfflineDiarizerManager) {
    self.manager = manager
  }

  /// Prevents new work and waits for every retained diarization task to
  /// unwind. Removing this instance from the registry then releases its
  /// CoreML-backed manager.
  func shutdown() async {
    await beginShutdown().value
  }

  /// Returns the one teardown task for this diarizer. Closing the operation
  /// store synchronously prevents a new call from racing disposal.
  func beginShutdown() -> Task<Void, Never> {
    shutdownLock.lock()
    defer { shutdownLock.unlock() }
    if let existing = shutdownTask {
      return existing
    }
    operations.close()
    let operations = operations
    let task = Task {
      await operations.cancelAllAndClose()
    }
    shutdownTask = task
    return task
  }
}

/// A lock-protected signal shared with FluidAudio's detached diarization
/// workers. Cancelling only the wrapper task is insufficient because those
/// workers do not inherit its cancellation state.
final class DiarizationCancellationSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var isCancelled = false

  func cancel() {
    lock.lock()
    isCancelled = true
    lock.unlock()
  }

  func checkCancellation() throws {
    lock.lock()
    let cancelled = isCancelled
    lock.unlock()
    if cancelled {
      throw CancellationError()
    }
  }
}

/// Makes cancellation visible inside FluidAudio's detached segmentation and
/// embedding tasks at every audio-source read boundary.
struct CancellableDiarizationAudioSource: AudioSampleSource {
  let base: any AudioSampleSource
  let cancellation: DiarizationCancellationSignal

  var sampleCount: Int { base.sampleCount }

  func copySamples(
    into destination: UnsafeMutablePointer<Float>,
    offset: Int,
    count: Int
  ) throws {
    try cancellation.checkCancellation()
    try base.copySamples(into: destination, offset: offset, count: count)
    try cancellation.checkCancellation()
  }
}

/// Streams per-chunk diarization progress, tagged with the instance id.
final class DiarizationProgressHandler: DiarizationProgressStreamHandler {
  private var sink: PigeonEventSink<DiarizationProgressMessage>?

  override func onListen(
    withArguments arguments: Any?, sink: PigeonEventSink<DiarizationProgressMessage>
  ) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(instanceId: Int64, processed: Int, total: Int) {
    let message = DiarizationProgressMessage(
      instanceId: instanceId, processedChunks: Int64(processed), totalChunks: Int64(total))
    if Thread.isMainThread {
      sink?.success(message)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(message) }
    }
  }
}

final class DiarizerHostApiImpl: DiarizerHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler
  private let diarizationProgress: DiarizationProgressHandler

  init(
    registry: InstanceRegistry,
    downloadProgress: DownloadProgressHandler,
    diarizationProgress: DiarizationProgressHandler
  ) {
    self.registry = registry
    self.downloadProgress = downloadProgress
    self.diarizationProgress = diarizationProgress
  }

  func create(
    clusteringThreshold: Double, numSpeakers: Int64?, minSpeakers: Int64?, maxSpeakers: Int64?,
    exposeChunkEmbeddings: Bool, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        var config = OfflineDiarizerConfig(clusteringThreshold: clusteringThreshold)
        config.clustering.numSpeakers = numSpeakers.map(Int.init)
        config.clustering.minSpeakers = minSpeakers.map(Int.init)
        config.clustering.maxSpeakers = maxSpeakers.map(Int.init)
        config.exposeChunkEmbeddings = exposeChunkEmbeddings

        // prepareModels() has no progress handler; load models explicitly so
        // first-run downloads surface progress like every other model load.
        let models = try await OfflineDiarizerModels.load(progressHandler: handler)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        let id = self.registry.add(DiarizerInstance(manager: manager))
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  private static func mapResult(_ result: DiarizationResult) -> DiarizationResultMessage {
    DiarizationResultMessage(
      segments: result.segments.map { segment in
        DiarizationSegmentMessage(
          speakerId: segment.speakerId,
          startSeconds: Double(segment.startTimeSeconds),
          endSeconds: Double(segment.endTimeSeconds),
          qualityScore: Double(segment.qualityScore),
          embedding: AudioBridge.typedData(from: segment.embedding)
        )
      },
      speakerDatabase: result.speakerDatabase.map { database in
        database.map { speakerId, embedding in
          SpeakerEmbeddingMessage(
            speakerId: speakerId, embedding: AudioBridge.typedData(from: embedding))
        }
        .sorted { $0.speakerId < $1.speakerId }
      },
      chunkEmbeddings: result.chunkEmbeddings.map { chunks in
        chunks.map { chunk in
          ChunkEmbeddingMessage(
            speakerId: chunk.speakerId,
            chunkIndex: Int64(chunk.chunkIndex),
            speakerIndex: Int64(chunk.speakerIndex),
            startSeconds: chunk.startTimeSeconds,
            endSeconds: chunk.endTimeSeconds,
            embedding256: AudioBridge.typedData(from: chunk.embedding256),
            rho128: chunk.rho128.withUnsafeBytes { FlutterStandardTypedData(bytes: Data($0)) }
          )
        }
      },
      timings: result.timings.map { timings in
        DiarizationTimingsMessage(
          segmentationSeconds: timings.segmentationSeconds,
          embeddingExtractionSeconds: timings.embeddingExtractionSeconds,
          speakerClusteringSeconds: timings.speakerClusteringSeconds,
          postProcessingSeconds: timings.postProcessingSeconds,
          totalInferenceSeconds: timings.totalInferenceSeconds,
          totalProcessingSeconds: timings.totalProcessingSeconds
        )
      }
    )
  }

  private func diarize(
    instanceId: Int64,
    operationId: Int64,
    completion: @escaping (Result<DiarizationResultMessage, Error>) -> Void,
    run: @escaping @Sendable (
      OfflineDiarizerManager, DiarizationCancellationSignal
    ) async throws -> DiarizationResult
  ) {
    let reply = OneShotResultCompletion(completion)
    guard let instance = registry.get(instanceId, as: DiarizerInstance.self) else {
      reply.resolve(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "diarizer")))
      return
    }
    let operation: RetainedInferenceOperation
    do {
      operation = try instance.operations.reserve(operationId)
    } catch {
      reply.resolve(.failure(ErrorMapping.map(error)))
      return
    }
    let manager = instance.manager
    let operations = instance.operations
    let cancellation = DiarizationCancellationSignal()
    let task = Task { [weak operations] in
      defer { operations?.finish(operationId) }
      do {
        try Task.checkCancellation()
        let result = try await run(manager, cancellation)
        // Cancellation can land after FluidAudio's final suspension point.
        // Resolve the Pigeon reply exactly once and never publish a successful
        // result after the caller requested cancellation.
        try Task.checkCancellation()
        reply.resolve(.success(Self.mapResult(result)))
      } catch is CancellationError {
        reply.resolve(.failure(ErrorMapping.operationCancelled(operationId)))
      } catch {
        reply.resolve(
          .failure(
            Task.isCancelled
              ? ErrorMapping.operationCancelled(operationId)
              : ErrorMapping.map(error)))
      }
    }
    operation.attach(task) {
      cancellation.cancel()
      // Linearize cancellation against a final successful reply. If success
      // already won, this is an after-completion no-op; otherwise the task's
      // later unwind cannot publish a second terminal result.
      reply.resolve(.failure(ErrorMapping.operationCancelled(operationId)))
    }
  }

  func diarizeSamples(
    instanceId: Int64, operationId: Int64, float32Samples: FlutterStandardTypedData,
    completion: @escaping (Result<DiarizationResultMessage, Error>) -> Void
  ) {
    let samples = AudioBridge.floats(from: float32Samples)
    let progress = diarizationProgress
    diarize(
      instanceId: instanceId, operationId: operationId, completion: completion
    ) { manager, cancellation in
        let source = CancellableDiarizationAudioSource(
          base: ArrayAudioSampleSource(samples: samples), cancellation: cancellation)
        return try await manager.process(
          audioSource: source, audioLoadingSeconds: 0
        ) { processed, total in
          progress.emit(instanceId: instanceId, processed: processed, total: total)
        }
      }
  }

  func diarizeFile(
    instanceId: Int64, operationId: Int64, path: String,
    completion: @escaping (Result<DiarizationResultMessage, Error>) -> Void
  ) {
    guard FileManager.default.fileExists(atPath: path) else {
      completion(
        .failure(PigeonError(code: "FileNotFound", message: "No file at \(path)", details: nil)))
      return
    }
    let progress = diarizationProgress
    let url = URL(fileURLWithPath: path)
    diarize(
      instanceId: instanceId, operationId: operationId, completion: completion
    ) { manager, cancellation in
        let (source, loadDuration) = try AudioSourceFactory().makeDiskBackedSource(
          from: url, targetSampleRate: 16_000)
        defer { source.cleanup() }
        try cancellation.checkCancellation()
        let cancellableSource = CancellableDiarizationAudioSource(
          base: source, cancellation: cancellation)
        return try await manager.process(
          audioSource: cancellableSource, audioLoadingSeconds: loadDuration
        ) {
          processed, total in
          progress.emit(instanceId: instanceId, processed: processed, total: total)
        }
      }
  }

  func cancel(
    instanceId: Int64, operationId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // Cancellation is deliberately idempotent. If dispose won the race, its
    // shutdown task already cancelled and awaited every retained operation.
    guard let instance = registry.get(instanceId, as: DiarizerInstance.self) else {
      completion(.success(()))
      return
    }
    Task {
      await instance.operations.cancel(operationId)
      completion(.success(()))
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let instance = registry.get(instanceId, as: DiarizerInstance.self) else {
      completion(.success(()))
      return
    }
    let shutdown = instance.beginShutdown()
    Task {
      await shutdown.value
      // Keep the closed instance addressable while shutdown is in flight so
      // a racing cancel call can await the same retained task.
      _ = self.registry.remove(instanceId)
      completion(.success(()))
    }
  }
}
