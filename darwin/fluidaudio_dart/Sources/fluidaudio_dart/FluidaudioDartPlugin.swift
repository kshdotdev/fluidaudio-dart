#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

/// Everything one plugin registration owns, with an idempotent teardown for
/// engine death (no dispose calls arrive from Dart in that case — without
/// this, a live mic capture would outlive the engine).
///
/// Strictly per-registration: multiple Flutter engines in one process
/// (FlutterEngineGroup, add-to-app) each get an independent runtime.
final class PluginRuntime {
  let registry: InstanceRegistry
  let microphone: MicrophoneHostApiImpl

  private let lock = NSLock()
  private var didTeardown = false

  init(registry: InstanceRegistry, microphone: MicrophoneHostApiImpl) {
    self.registry = registry
    self.microphone = microphone
  }

  func teardown() {
    lock.lock()
    let isFirstCall = !didTeardown
    didTeardown = true
    lock.unlock()
    guard isFirstCall else { return }
    microphone.teardown()
    registry.shutdownAll()
  }
}

public class FluidaudioDartPlugin: NSObject, FlutterPlugin {
  private let runtime: PluginRuntime

  init(runtime: PluginRuntime) {
    self.runtime = runtime
  }

  deinit {
    // macOS path: the registrar retains this instance for the engine's
    // lifetime (via addMethodCallDelegate); engine death releases it and
    // teardown runs here. On iOS this is a backstop after detachFromEngine.
    runtime.teardown()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #elseif os(macOS)
      let messenger = registrar.messenger
    #endif

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
    let plugin = FluidaudioDartPlugin(runtime: runtime)

    #if os(iOS)
      // Publish the instance so detachFromEngine(for:) fires on engine death.
      registrar.publish(plugin)
    #elseif os(macOS)
      // No detach callback exists on macOS; instead let the registrar retain
      // the instance for the engine's lifetime so deinit runs teardown when
      // the engine is destroyed.
      let lifetimeChannel = FlutterMethodChannel(
        name: "fluidaudio_dart/lifetime", binaryMessenger: messenger)
      registrar.addMethodCallDelegate(plugin, channel: lifetimeChannel)
    #endif
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }

  #if os(iOS)
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
      runtime.teardown()
    }
  #endif
}
