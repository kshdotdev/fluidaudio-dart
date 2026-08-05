import Foundation

/// Thread-safe one-shot delivery for asynchronous Pigeon replies. Native
/// cancellation, disposal, and inference failures may race, but Flutter must
/// observe exactly one terminal result.
final class OneShotResultCompletion<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var completion: ((Result<Value, Error>) -> Void)?

  init(_ completion: @escaping (Result<Value, Error>) -> Void) {
    self.completion = completion
  }

  func resolve(_ result: Result<Value, Error>) {
    lock.lock()
    let pending = completion
    completion = nil
    lock.unlock()
    pending?(result)
  }
}

/// Registration failures are programming/protocol errors rather than model
/// inference failures, so keep them explicit at the channel boundary.
enum InferenceOperationStoreError: LocalizedError {
  case closed(String)
  case duplicate(String, Int64)

  var errorDescription: String? {
    switch self {
    case .closed(let operationKind):
      return "The \(operationKind) instance is disposing and cannot start another operation."
    case .duplicate(let operationKind, let id):
      return "\(operationKind) operation id \(id) is already active for this instance."
    }
  }
}

/// Owns one native inference task and makes a cancellation request that races
/// task attachment safe. The latter matters because platform messages may be
/// dispatched on different queues even though task registration is tiny.
final class RetainedInferenceOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancellationRequested = false
  private var cancellationHandler: (@Sendable () -> Void)?
  private var cancellationHandlerDelivered = false
  private var attachmentWaiters: [CheckedContinuation<Task<Void, Never>, Never>] = []

  func attach(
    _ task: Task<Void, Never>,
    onCancel cancellationHandler: @escaping @Sendable () -> Void = {}
  ) {
    lock.lock()
    precondition(self.task == nil, "An inference operation task may only be attached once.")
    self.task = task
    self.cancellationHandler = cancellationHandler
    let shouldCancel = cancellationRequested
    let handler = takeCancellationHandlerIfNeeded()
    let waiters = attachmentWaiters
    attachmentWaiters.removeAll()
    lock.unlock()

    handler?()
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
    let handler = takeCancellationHandlerIfNeeded()
    lock.unlock()
    handler?()
    return attached
  }

  /// Must be called with [lock] held. Delivery is exactly once even when
  /// several callers cancel concurrently or cancellation precedes attachment.
  private func takeCancellationHandlerIfNeeded() -> (@Sendable () -> Void)? {
    guard cancellationRequested, !cancellationHandlerDelivered,
      let cancellationHandler
    else {
      return nil
    }
    cancellationHandlerDelivered = true
    return cancellationHandler
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

/// Lock-protected operation ownership for one loaded inference pipeline.
///
/// Keeping `Task` handles here is the load-bearing cancellation seam: dropping
/// the Dart `Future` alone cannot stop CoreML inference.
final class InferenceOperationStore: @unchecked Sendable {
  private let operationKind: String
  private let lock = NSLock()
  private var operations: [Int64: RetainedInferenceOperation] = [:]
  private var isClosed = false

  init(operationKind: String) {
    self.operationKind = operationKind
  }

  func reserve(_ id: Int64) throws -> RetainedInferenceOperation {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else { throw InferenceOperationStoreError.closed(operationKind) }
    guard operations[id] == nil else {
      throw InferenceOperationStoreError.duplicate(operationKind, id)
    }
    let operation = RetainedInferenceOperation()
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

  private func operation(for id: Int64) -> RetainedInferenceOperation? {
    lock.lock()
    defer { lock.unlock() }
    return operations[id]
  }

  private func closeAndSnapshot() -> [Int64: RetainedInferenceOperation] {
    lock.lock()
    isClosed = true
    let active = operations
    lock.unlock()
    return active
  }
}
