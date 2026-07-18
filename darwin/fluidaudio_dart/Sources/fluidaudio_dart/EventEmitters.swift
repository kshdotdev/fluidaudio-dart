import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Stream handler for the `debugEvents` diagnostic channel.
///
/// Event sinks must be called on the platform thread; `emit` hops to main.
final class DebugEventsHandler: DebugEventsStreamHandler {
  private var sink: PigeonEventSink<DebugEventMessage>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<DebugEventMessage>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(_ event: DebugEventMessage) {
    if Thread.isMainThread {
      sink?.success(event)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.sink?.success(event)
      }
    }
  }
}
