import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Generic pigeon stream handler that stores the sink and emits on the
/// platform (main) thread, as required by Flutter event channels.
private func emitOnMain(_ block: @escaping () -> Void) {
  if Thread.isMainThread {
    block()
  } else {
    DispatchQueue.main.async(execute: block)
  }
}

/// Stream handler for the `debugEvents` diagnostic channel.
final class DebugEventsHandler: DebugEventsStreamHandler {
  private var sink: PigeonEventSink<DebugEventMessage>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<DebugEventMessage>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(_ event: DebugEventMessage) {
    emitOnMain { [weak self] in self?.sink?.success(event) }
  }
}

/// Streams `SlidingWindowTranscriptionUpdate`s, tagged with the session id.
final class TranscriptionUpdatesHandler: TranscriptionUpdatesStreamHandler {
  private var sink: PigeonEventSink<TranscriptionUpdateMessage>?

  override func onListen(
    withArguments arguments: Any?, sink: PigeonEventSink<TranscriptionUpdateMessage>
  ) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(instanceId: Int64, update: SlidingWindowTranscriptionUpdate) {
    let message = TranscriptionUpdateMessage(
      instanceId: instanceId,
      text: update.text,
      isConfirmed: update.isConfirmed,
      confidence: Double(update.confidence),
      tokenTimings: update.tokenTimings.map(TypeMapping.tokenTiming)
    )
    emitOnMain { [weak self] in self?.sink?.success(message) }
  }
}

/// Streams model download/compile progress, tagged with a caller token.
final class DownloadProgressHandler: DownloadProgressStreamHandler {
  private var sink: PigeonEventSink<DownloadProgressMessage>?

  override func onListen(
    withArguments arguments: Any?, sink: PigeonEventSink<DownloadProgressMessage>
  ) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(progressToken: Int64, progress: DownloadProgress) {
    let message: DownloadProgressMessage
    switch progress.phase {
    case .listing:
      message = DownloadProgressMessage(
        progressToken: progressToken, fraction: progress.fractionCompleted, phase: .listing)
    case .downloading(let completedFiles, let totalFiles):
      message = DownloadProgressMessage(
        progressToken: progressToken, fraction: progress.fractionCompleted, phase: .downloading,
        completedFiles: Int64(completedFiles), totalFiles: Int64(totalFiles))
    case .compiling(let modelName):
      message = DownloadProgressMessage(
        progressToken: progressToken, fraction: progress.fractionCompleted, phase: .compiling,
        modelName: modelName)
    }
    emitOnMain { [weak self] in self?.sink?.success(message) }
  }

  func emitCompleted(progressToken: Int64) {
    let message = DownloadProgressMessage(
      progressToken: progressToken, fraction: 1.0, phase: .completed)
    emitOnMain { [weak self] in self?.sink?.success(message) }
  }

  func emitFailed(progressToken: Int64, error: Error) {
    let message = DownloadProgressMessage(
      progressToken: progressToken, fraction: 0.0, phase: .failed,
      errorMessage: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    emitOnMain { [weak self] in self?.sink?.success(message) }
  }

  /// FluidAudio's `ProgressHandler` closure bound to a token.
  func progressHandler(for token: Int64) -> ProgressHandler {
    { [weak self] progress in
      self?.emit(progressToken: token, progress: progress)
    }
  }
}

/// Streams per-chunk VAD results and segmentation events.
final class VadEventsHandler: VadEventsStreamHandler {
  private var sink: PigeonEventSink<VadStreamEventMessage>?

  override func onListen(
    withArguments arguments: Any?, sink: PigeonEventSink<VadStreamEventMessage>
  ) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(streamId: Int64, result: VadStreamResult) {
    let message = VadStreamEventMessage(
      instanceId: streamId,
      probability: Double(result.probability),
      isSpeechStart: result.event?.kind == .speechStart,
      isSpeechEnd: result.event?.kind == .speechEnd,
      sampleIndex: result.event.map { Int64($0.sampleIndex) },
      timeSeconds: result.event?.time
    )
    emitOnMain { [weak self] in self?.sink?.success(message) }
  }
}

/// Shared FluidAudio → pigeon DTO conversions.
enum TypeMapping {
  static func tokenTiming(_ timing: TokenTiming) -> TokenTimingMessage {
    TokenTimingMessage(
      token: timing.token,
      tokenId: Int64(timing.tokenId),
      startSeconds: timing.startTime,
      endSeconds: timing.endTime,
      confidence: Double(timing.confidence)
    )
  }

  static func asrResult(_ result: ASRResult) -> AsrResultMessage {
    AsrResultMessage(
      text: result.text,
      confidence: Double(result.confidence),
      durationSeconds: result.duration,
      processingSeconds: result.processingTime,
      tokenTimings: result.tokenTimings.map { $0.map(tokenTiming) }
    )
  }
}
