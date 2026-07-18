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

    let registry = InstanceRegistry()

    let debugEvents = DebugEventsHandler()
    let transcriptionUpdates = TranscriptionUpdatesHandler()
    let downloadProgress = DownloadProgressHandler()
    let vadEvents = VadEventsHandler()
    let diarizationProgress = DiarizationProgressHandler()
    let eouEvents = EouEventsHandler()
    let ttsChunks = TtsChunksHandler()

    DebugEventsStreamHandler.register(with: messenger, streamHandler: debugEvents)
    TranscriptionUpdatesStreamHandler.register(with: messenger, streamHandler: transcriptionUpdates)
    DownloadProgressStreamHandler.register(with: messenger, streamHandler: downloadProgress)
    VadEventsStreamHandler.register(with: messenger, streamHandler: vadEvents)
    DiarizationProgressStreamHandler.register(with: messenger, streamHandler: diarizationProgress)
    EouEventsStreamHandler.register(with: messenger, streamHandler: eouEvents)
    TtsChunksStreamHandler.register(with: messenger, streamHandler: ttsChunks)

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
  }
}
