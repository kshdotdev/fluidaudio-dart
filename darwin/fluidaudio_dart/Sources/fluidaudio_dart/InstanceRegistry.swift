import Foundation

/// Thread-safe map from channel-visible instance ids to live native objects.
///
/// Platform channels are stateless; every stateful FluidAudio manager is
/// addressed by the id returned from its create/load call.
final class InstanceRegistry {
  private let lock = NSLock()
  private var nextId: Int64 = 1
  private var instances: [Int64: Any] = [:]

  func add(_ instance: Any) -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    let id = nextId
    nextId += 1
    instances[id] = instance
    return id
  }

  func get<T>(_ id: Int64, as type: T.Type) -> T? {
    lock.lock()
    defer { lock.unlock() }
    return instances[id] as? T
  }

  @discardableResult
  func remove(_ id: Int64) -> Any? {
    lock.lock()
    defer { lock.unlock() }
    return instances.removeValue(forKey: id)
  }

  func removeAll() -> [Any] {
    lock.lock()
    defer { lock.unlock() }
    let all = Array(instances.values)
    instances.removeAll()
    return all
  }

  /// Best-effort native teardown of every live instance — used when the
  /// Flutter engine detaches or the plugin re-registers, where no dispose
  /// calls will ever arrive from Dart.
  func shutdownAll() {
    for instance in removeAll() {
      switch instance {
      case let streaming as StreamingAsrInstance:
        let manager = streaming.manager
        streaming.queue.enqueue {
          await manager.cleanup()
          streaming.shutdown()
        }
      case let eou as EouInstance:
        let manager = eou.manager
        eou.queue.enqueue {
          await manager.cleanup()
          eou.queue.shutdown()
        }
      case let vadStream as VadStreamInstance:
        vadStream.queue.shutdown()
      case let asr as AsrInstance:
        let manager = asr.manager
        Task { await manager.cleanup() }
      case let kokoro as KokoroInstance:
        let manager = kokoro.manager
        Task { await manager.cleanup() }
      case let pocket as PocketInstance:
        let manager = pocket.manager
        Task { await manager.cleanup() }
      default:
        break
      }
    }
  }
}

/// Runs async operations strictly in enqueue order, one at a time.
///
/// Streaming audio MUST be fed sequentially from a single consumer —
/// concurrent `streamAudio` calls reorder the decode stream (ectos lesson).
/// Pigeon handlers spawn a Task per call with no FIFO guarantee, so feed
/// operations are funneled through this queue instead.
final class SerialTaskQueue {
  private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation
  private let task: Task<Void, Never>

  init() {
    var streamContinuation: AsyncStream<@Sendable () async -> Void>.Continuation!
    let stream = AsyncStream<@Sendable () async -> Void> { streamContinuation = $0 }
    continuation = streamContinuation
    task = Task {
      for await operation in stream {
        await operation()
      }
    }
  }

  func enqueue(_ operation: @escaping @Sendable () async -> Void) {
    continuation.yield(operation)
  }

  func shutdown() {
    continuation.finish()
    task.cancel()
  }
}
