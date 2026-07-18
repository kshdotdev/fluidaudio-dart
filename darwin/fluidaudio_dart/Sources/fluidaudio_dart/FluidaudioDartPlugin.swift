#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

/// Everything one plugin registration owns, with a teardown path for engine
/// detach / re-registration (no dispose calls arrive from Dart in either
/// case — without this, a live mic capture would outlive the engine).
final class PluginRuntime {
  let registry: InstanceRegistry
  let microphone: MicrophoneHostApiImpl

  init(registry: InstanceRegistry, microphone: MicrophoneHostApiImpl) {
    self.registry = registry
    self.microphone = microphone
  }

  func teardown() {
    microphone.teardown()
    registry.shutdownAll()
  }
}

public class FluidaudioDartPlugin: NSObject, FlutterPlugin {
  private static var activeRuntime: PluginRuntime?

  private let runtime: PluginRuntime

  init(runtime: PluginRuntime) {
    self.runtime = runtime
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #elseif os(macOS)
      let messenger = registrar.messenger
    #endif

    // A stale runtime from a previous engine must not keep the mic hot.
    activeRuntime?.teardown()

    let registry = InstanceRegistry()

    let debugEvents = DebugEventsHandler()
    let transcriptionUpdates = TranscriptionUpdatesHandler()
    let downloadProgress = DownloadProgressHandler()
    let vadEvents = VadEventsHandler()
    let diarizationProgress = DiarizationProgressHandler()
    let eouEvents = EouEventsHandler()
    let ttsChunks = TtsChunksHandler()
    let micFrames = MicFramesHandler()

    DebugEventsStreamHandler.register(with: messenger, streamHandler: debugEvents)
    TranscriptionUpdatesStreamHandler.register(with: messenger, streamHandler: transcriptionUpdates)
    DownloadProgressStreamHandler.register(with: messenger, streamHandler: downloadProgress)
    VadEventsStreamHandler.register(with: messenger, streamHandler: vadEvents)
    DiarizationProgressStreamHandler.register(with: messenger, streamHandler: diarizationProgress)
    EouEventsStreamHandler.register(with: messenger, streamHandler: eouEvents)
    TtsChunksStreamHandler.register(with: messenger, streamHandler: ttsChunks)
    MicFramesStreamHandler.register(with: messenger, streamHandler: micFrames)

    let microphone = MicrophoneHostApiImpl(
      registry: registry, frames: micFrames, vadEvents: vadEvents)

    SystemHostApiSetup.setUp(
      binaryMessenger: messenger, api: SystemHostApiImpl(debugEvents: debugEvents))
    ModelsHostApiSetup.setUp(
      binaryMessenger: messenger, api: ModelsHostApiImpl(downloadProgress: downloadProgress))
    AsrHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: AsrHostApiImpl(registry: registry, downloadProgress: downloadProgress))
    StreamingAsrHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: StreamingAsrHostApiImpl(
        registry: registry, downloadProgress: downloadProgress, updates: transcriptionUpdates))
    VadHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: VadHostApiImpl(registry: registry, downloadProgress: downloadProgress, events: vadEvents))
    DiarizerHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: DiarizerHostApiImpl(
        registry: registry, downloadProgress: downloadProgress,
        diarizationProgress: diarizationProgress))
    EouHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: EouHostApiImpl(registry: registry, downloadProgress: downloadProgress, events: eouEvents))
    CtcVocabularyHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: CtcVocabularyHostApiImpl(registry: registry, downloadProgress: downloadProgress))
    ItnHostApiSetup.setUp(binaryMessenger: messenger, api: ItnHostApiImpl())
    TtsHostApiSetup.setUp(
      binaryMessenger: messenger,
      api: TtsHostApiImpl(registry: registry, downloadProgress: downloadProgress, chunks: ttsChunks))
    AudioHostApiSetup.setUp(binaryMessenger: messenger, api: AudioHostApiImpl())
    MicrophoneHostApiSetup.setUp(binaryMessenger: messenger, api: microphone)

    let runtime = PluginRuntime(registry: registry, microphone: microphone)
    activeRuntime = runtime

    #if os(iOS)
      // Publish the instance so detachFromEngine(for:) fires on engine death.
      let plugin = FluidaudioDartPlugin(runtime: runtime)
      registrar.publish(plugin)
    #endif
  }

  #if os(iOS)
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
      runtime.teardown()
      if FluidaudioDartPlugin.activeRuntime === runtime {
        FluidaudioDartPlugin.activeRuntime = nil
      }
    }
  #endif
}
