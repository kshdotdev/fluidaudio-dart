import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'capture_health.dart';
import 'eou.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'microphone.dart';
import 'streaming_asr.dart';
import 'vad.dart';

/// A process currently known to Core Audio — a candidate for a targeted tap.
class FluidAudioProcess {
  const FluidAudioProcess({
    required this.pid,
    required this.bundleId,
    required this.isPlayingAudio,
  });

  final int pid;

  /// Bundle identifier (helpers keep their own ids, e.g.
  /// `com.google.Chrome.helper` under Chrome); may be empty.
  final String bundleId;

  /// Whether the process currently has running audio output.
  final bool isPlayingAudio;
}

/// System-audio capture via Core Audio process taps (macOS 14.4+ only).
///
/// Captures what other applications are playing — all of them by default, or
/// only specific processes via [start]'s `processIds` — resampled natively to
/// 16 kHz mono and fanned out directly to the attached sessions, exactly like
/// [FluidMicrophone]. This is the "other participants" track of a meeting
/// transcriber.
///
/// Requirements:
/// - macOS 14.4+ (check [isSupported]; always false on iOS)
/// - the "System Audio Recording" permission
///   (`NSAudioCaptureUsageDescription` in Info.plist; the OS prompts on the
///   first tap attempt — see [requestPermission])
/// - an unsandboxed app, or the appropriate sandbox exceptions
///
/// Note: a process only becomes tappable by PID once it has opened audio.
class FluidSystemAudio {
  FluidSystemAudio({
    @visibleForTesting messages.SystemAudioHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  })  : _hostApi = hostApi ?? messages.SystemAudioHostApi(),
        _events = events ?? FluidEventHub.instance;

  final messages.SystemAudioHostApi _hostApi;
  final FluidEventHub _events;

  /// Whether process-tap capture is available on this platform.
  Future<bool> get isSupported => wrapPlatformErrors(() => _hostApi.isSupported());

  /// Lists processes known to Core Audio (no permission needed for this
  /// metadata). Match by [FluidAudioProcess.bundleId] — including helper
  /// processes, which carry the audio for Electron/Chromium apps — and pass
  /// the PIDs to [start]. A process appears here only once it has opened
  /// audio.
  Future<List<FluidAudioProcess>> listAudioProcesses() async {
    final processes = await wrapPlatformErrors(() => _hostApi.listAudioProcesses());
    return [
      for (final process in processes)
        FluidAudioProcess(
          pid: process.pid,
          bundleId: process.bundleId,
          isPlayingAudio: process.isPlayingAudio,
        ),
    ];
  }

  /// Preflights the System Audio Recording permission; the OS shows its
  /// prompt on the first attempt. Returns whether tapping is currently
  /// allowed.
  Future<bool> requestPermission() =>
      wrapPlatformErrors(() => _hostApi.requestPermission());

  /// Starts capture. With an empty [processIds], captures all system audio
  /// except this app's own output; otherwise only the given PIDs.
  ///
  /// A non-null [recordToWavPath] additionally tees the capture into a WAV
  /// file at that path — written natively on the capture queue, so audio
  /// still never crosses the platform channel, and recording coexists with
  /// every live attachment (it also survives the watchdog's one-shot chain
  /// rebuild). Pure sink semantics: it never starts or stops the capture,
  /// and the file is finalized on [stop]. The written stream is the
  /// ASR-grade 16 kHz mono pipeline (16-bit PCM WAV); archival fidelity
  /// would need a pre-resample tap, which this library does not provide.
  /// Naming, rotation and retention are the caller's concern.
  Future<void> start({
    List<int> processIds = const [],
    List<FluidStreamingAsr> transcribers = const [],
    List<FluidEou> turnDetectors = const [],
    List<FluidVadStream> vadStreams = const [],
    bool emitFrames = false,
    String? recordToWavPath,
  }) {
    return wrapPlatformErrors(
      () => _hostApi.start(
        processIds,
        [for (final session in transcribers) session.channelInstanceId],
        [for (final session in turnDetectors) session.channelInstanceId],
        [for (final stream in vadStreams) stream.channelInstanceId],
        emitFrames,
        recordToWavPath,
      ),
    );
  }

  Future<void> stop() => wrapPlatformErrors(() => _hostApi.stop());

  Future<bool> get isRunning => wrapPlatformErrors(() => _hostApi.isRunning());

  /// Captured frames (only emitted while running with `emitFrames: true`).
  Stream<FluidMicFrame> get frames => _events.systemAudioFrames.map(
        (frame) => FluidMicFrame(samples: bytesToFloats(frame.samples), rms: frame.rms),
      );

  /// Watchdog phase transitions: after [start], a ~2 s self-test either
  /// resolves [CaptureHealthPhase.healthy], or rebuilds the tap once with
  /// fresh process translation ([CaptureHealthPhase.rebuilding]) before
  /// settling on healthy, informational [CaptureHealthPhase.silent] (tap
  /// alive, nothing playing), or [CaptureHealthPhase.failed] (chain dead —
  /// the capture is stopped).
  Stream<FluidCaptureHealth> get health => _events
      .captureHealthFor(messages.CaptureSourceMessage.systemAudio)
      .map(mapCaptureHealth);
}
