#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

public class FluidaudioDartPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #elseif os(macOS)
      let messenger = registrar.messenger
    #endif

    let debugEvents = DebugEventsHandler()
    DebugEventsStreamHandler.register(with: messenger, streamHandler: debugEvents)
    SystemHostApiSetup.setUp(
      binaryMessenger: messenger, api: SystemHostApiImpl(debugEvents: debugEvents))
  }
}
