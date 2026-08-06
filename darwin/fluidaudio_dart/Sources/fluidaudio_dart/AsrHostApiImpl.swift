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
  let operations = AsrOperationStore()
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

/// Registration failures are programming/protocol errors rather than model
/// inference failures, so keep them explicit at the channel boundary.
enum AsrOperationStoreError: LocalizedError {
  case closed
  case duplicate(Int64)

  var errorDescription: String? {
    switch self {
    case .closed:
      return "The ASR instance is disposing and cannot start another operation."
    case .duplicate(let id):
      return "ASR operation id \(id) is already active for this instance."
    }
  }
}

/// Owns one native inference task and makes a cancellation request that races
/// task attachment safe. The latter matters because platform messages may be
/// dispatched on different queues even though task registration is tiny.
final class AsrInferenceOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancellationRequested = false
  private var attachmentWaiters: [CheckedContinuation<Task<Void, Never>, Never>] = []

  func attach(_ task: Task<Void, Never>) {
    lock.lock()
    precondition(self.task == nil, "An ASR operation task may only be attached once.")
    self.task = task
    let shouldCancel = cancellationRequested
    let waiters = attachmentWaiters
    attachmentWaiters.removeAll()
    lock.unlock()

    if shouldCancel {
      task.cancel()
    }
    for waiter in waiters {
      waiter.resume(returning: task)
    }
  }

  /// Completes only when the retained task has observed cancellation and
  /// returned. Repeated/concurrent requests all await the same task.
  func cancelAndWait() async {
    let attached: Task<Void, Never>
    if let current = requestCancellation() {
      attached = current
    } else {
      attached = await waitForAttachment()
    }
    attached.cancel()
    await attached.value
  }

  private func requestCancellation() -> Task<Void, Never>? {
    lock.lock()
    cancellationRequested = true
    let attached = task
    lock.unlock()
    return attached
  }

  private func waitForAttachment() async -> Task<Void, Never> {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let attached = task {
        lock.unlock()
        continuation.resume(returning: attached)
      } else {
        attachmentWaiters.append(continuation)
        lock.unlock()
      }
    }
  }
}

/// Lock-protected operation ownership for one loaded recognizer.
///
/// Keeping `Task` handles here is the load-bearing cancellation seam: dropping
/// the Dart `Future` alone cannot stop CoreML inference.
final class AsrOperationStore: @unchecked Sendable {
  private let lock = NSLock()
  private var operations: [Int64: AsrInferenceOperation] = [:]
  private var isClosed = false

  func reserve(_ id: Int64) throws -> AsrInferenceOperation {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else { throw AsrOperationStoreError.closed }
    guard operations[id] == nil else { throw AsrOperationStoreError.duplicate(id) }
    let operation = AsrInferenceOperation()
    operations[id] = operation
    return operation
  }

  func finish(_ id: Int64) {
    lock.lock()
    operations.removeValue(forKey: id)
    lock.unlock()
  }

  func cancel(_ id: Int64) async {
    let operation = operation(for: id)
    await operation?.cancelAndWait()
  }

  func cancelAllAndClose() async {
    let active = closeAndSnapshot()
    await withTaskGroup(of: Void.self) { group in
      for operation in active.values {
        group.addTask {
          await operation.cancelAndWait()
        }
      }
    }
    for id in active.keys {
      finish(id)
    }
  }

  func close() {
    lock.lock()
    isClosed = true
    lock.unlock()
  }

  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return operations.count
  }

  private func operation(for id: Int64) -> AsrInferenceOperation? {
    lock.lock()
    defer { lock.unlock() }
    return operations[id]
  }

  private func closeAndSnapshot() -> [Int64: AsrInferenceOperation] {
    lock.lock()
    isClosed = true
    let active = operations
    lock.unlock()
    return active
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
          to: ModelPaths.asrRepoDirectory(modelVersion),
          version: modelVersion, progressHandler: handler)
        let config = ASRConfig(
          tdtConfig: TdtConfig(blankId: modelVersion.blankId),
          encoderHiddenSize: modelVersion.encoderHiddenSize
        )
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        ModelPaths.registerInstanceCreated()
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
    let operation: AsrInferenceOperation
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
