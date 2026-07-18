import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class DiarizerInstance {
  let manager: OfflineDiarizerManager

  init(manager: OfflineDiarizerManager) {
    self.manager = manager
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

  private func mapResult(_ result: DiarizationResult) -> DiarizationResultMessage {
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

  func diarizeSamples(
    instanceId: Int64, float32Samples: FlutterStandardTypedData,
    completion: @escaping (Result<DiarizationResultMessage, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: DiarizerInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "diarizer")))
      return
    }
    let samples = AudioBridge.floats(from: float32Samples)
    let progress = diarizationProgress
    Task {
      do {
        let result = try await instance.manager.process(audio: samples) { processed, total in
          progress.emit(instanceId: instanceId, processed: processed, total: total)
        }
        completion(.success(self.mapResult(result)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func diarizeFile(
    instanceId: Int64, path: String,
    completion: @escaping (Result<DiarizationResultMessage, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: DiarizerInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "diarizer")))
      return
    }
    guard FileManager.default.fileExists(atPath: path) else {
      completion(
        .failure(PigeonError(code: "FileNotFound", message: "No file at \(path)", details: nil)))
      return
    }
    let progress = diarizationProgress
    Task {
      do {
        let result = try await instance.manager.process(URL(fileURLWithPath: path)) {
          processed, total in
          progress.emit(instanceId: instanceId, processed: processed, total: total)
        }
        completion(.success(self.mapResult(result)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    registry.remove(instanceId)
    completion(.success(()))
  }
}
