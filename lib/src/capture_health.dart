import 'messages.g.dart' as messages;

/// Watchdog phase of a running capture.
enum CaptureHealthPhase {
  /// Self-test window right after start (~2 s).
  validating,

  /// Audio with real content is flowing.
  healthy,

  /// The system tap was silent; it is being rebuilt once with fresh process
  /// translation (Electron/Chromium helpers often become tappable only after
  /// they open audio).
  rebuilding,

  /// Callbacks fire but every frame is zero. For the microphone this usually
  /// means muted; for system audio it can simply mean nothing is playing.
  /// Informational — the capture keeps running.
  silent,

  /// The capture produced no callbacks and could not be recovered; it has
  /// been stopped.
  failed,
}

/// A capture watchdog event (emitted on phase transitions).
class FluidCaptureHealth {
  const FluidCaptureHealth({
    required this.phase,
    required this.callbackCount,
    required this.receivingAudio,
    this.detail,
  });

  final CaptureHealthPhase phase;

  /// Device callbacks observed since start/rebuild.
  final int callbackCount;

  /// Whether any non-zero frame has been observed.
  final bool receivingAudio;

  final String? detail;
}

FluidCaptureHealth mapCaptureHealth(messages.CaptureHealthMessage event) {
  return FluidCaptureHealth(
    phase: CaptureHealthPhase.values[event.phase.index],
    callbackCount: event.callbackCount,
    receivingAudio: event.receivingAudio,
    detail: event.detail,
  );
}
