import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// A loaded batch-ASR pipeline: the manager plus the version it was built for
/// (the version drives fresh decoder-state layout per transcribe call).
final class AsrInstance {
  let manager: AsrManager
  let version: AsrModelVersion
  let operations = InferenceOperationStore(operationKind: "ASR")
  private let shutdownLock = NSLock()
  private var shutdownTask: Task<Void, Never>?

  init(manager: AsrManager, version: AsrModelVersion) {
    self.manager = manager
    self.version = version
  }

  /// Prevents new work, waits for every retained inference task to unwind,
  /// then releases the heavyweight CoreML models.
  func shutdown() async {
    await beginShutdown().value
  }

  /// Returns the one process-wide teardown task for this recognizer. Closing
  /// the operation store synchronously prevents a transcription from slipping
  /// in after disposal starts.
  func beginShutdown() -> Task<Void, Never> {
    shutdownLock.lock()
    defer { shutdownLock.unlock() }
    if let existing = shutdownTask {
      return existing
    }
    operations.close()
    let operations = operations
    let manager = manager
    let task = Task {
      await operations.cancelAllAndClose()
      await manager.cleanup()
    }
    shutdownTask = task
    return task
  }
}

final class AsrHostApiImpl: AsrHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler

  init(registry: InstanceRegistry, downloadProgress: DownloadProgressHandler) {
    self.registry = registry
    self.downloadProgress = downloadProgress
  }

  private static func version(for message: AsrVersionMessage) -> AsrModelVersion {
    switch message {
    case .v2: return .v2
    case .v3: return .v3
    }
  }

  func load(
    version: AsrVersionMessage, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let modelVersion = Self.version(for: version)
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        let models = try await AsrModels.downloadAndLoad(
          version: modelVersion, progressHandler: handler)
        let config = ASRConfig(
          tdtConfig: TdtConfig(blankId: modelVersion.blankId),
          encoderHiddenSize: modelVersion.encoderHiddenSize
        )
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        let id = self.registry.add(AsrInstance(manager: manager, version: modelVersion))
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  private func transcribe(
    instanceId: Int64,
    operationId: Int64,
    languageCode: String?,
    completion: @escaping (Result<AsrResultMessage, Error>) -> Void,
    run: @escaping @Sendable (AsrManager, inout TdtDecoderState, Language?) async throws -> ASRResult
  ) {
    guard let instance = registry.get(instanceId, as: AsrInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "ASR")))
      return
    }
    let operation: RetainedInferenceOperation
    do {
      operation = try instance.operations.reserve(operationId)
    } catch {
      completion(.failure(ErrorMapping.map(error)))
      return
    }
    let language = languageCode.flatMap(Language.init(rawValue:))
    let manager = instance.manager
    let version = instance.version
    let operations = instance.operations
    let task = Task { [weak operations] in
      defer { operations?.finish(operationId) }
      do {
        try Task.checkCancellation()
        // Fresh decoder state per one-shot call: reusing it leaks LSTM state
        // across utterances and collapses output (fluidaudio-rs lesson).
        var decoderState = TdtDecoderState.make(decoderLayers: version.decoderLayers)
        let result = try await run(manager, &decoderState, language)
        // A cancellation may arrive during the final non-suspending native
        // stage. Never publish a successful result after it was requested.
        try Task.checkCancellation()
        completion(.success(TypeMapping.asrResult(result)))
      } catch is CancellationError {
        completion(.failure(ErrorMapping.operationCancelled(operationId)))
      } catch {
        completion(
          .failure(
            Task.isCancelled
              ? ErrorMapping.operationCancelled(operationId)
              : ErrorMapping.map(error)))
      }
    }
    operation.attach(task)
  }

  func transcribeSamples(
    instanceId: Int64, operationId: Int64, float32Samples: FlutterStandardTypedData,
    languageCode: String?,
    completion: @escaping (Result<AsrResultMessage, Error>) -> Void
  ) {
    let samples = AudioBridge.floats(from: float32Samples)
    transcribe(
      instanceId: instanceId, operationId: operationId, languageCode: languageCode,
      completion: completion
    ) { manager, state, language in
        try await manager.transcribe(samples, decoderState: &state, language: language)
      }
  }

  func transcribeFile(
    instanceId: Int64, operationId: Int64, path: String, languageCode: String?,
    completion: @escaping (Result<AsrResultMessage, Error>) -> Void
  ) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      completion(
        .failure(
          PigeonError(code: "FileNotFound", message: "No file at \(path)", details: nil)))
      return
    }
    transcribe(
      instanceId: instanceId, operationId: operationId, languageCode: languageCode,
      completion: completion
    ) { manager, state, language in
        try await manager.transcribe(url, decoderState: &state, language: language)
      }
  }

  func cancel(
    instanceId: Int64, operationId: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // Cancellation is deliberately idempotent. An instance can disappear
    // because dispose won the race; that dispose already cancelled its work.
    guard let instance = registry.get(instanceId, as: AsrInstance.self) else {
      completion(.success(()))
      return
    }
    Task {
      await instance.operations.cancel(operationId)
      completion(.success(()))
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let instance = registry.get(instanceId, as: AsrInstance.self) else {
      completion(.success(()))
      return
    }
    let shutdown = instance.beginShutdown()
    Task {
      await shutdown.value
      // Keep the closed instance addressable while shutdown is in flight so
      // a racing cancel call can still await its retained task.
      _ = self.registry.remove(instanceId)
      completion(.success(()))
    }
  }
}
