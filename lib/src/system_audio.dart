import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'eou.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'microphone.dart';
import 'streaming_asr.dart';
import 'vad.dart';

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

  /// Preflights the System Audio Recording permission; the OS shows its
  /// prompt on the first attempt. Returns whether tapping is currently
  /// allowed.
  Future<bool> requestPermission() =>
      wrapPlatformErrors(() => _hostApi.requestPermission());

  /// Starts capture. With an empty [processIds], captures all system audio
  /// except this app's own output; otherwise only the given PIDs.
  Future<void> start({
    List<int> processIds = const [],
    List<FluidStreamingAsr> transcribers = const [],
    List<FluidEou> turnDetectors = const [],
    List<FluidVadStream> vadStreams = const [],
    bool emitFrames = false,
  }) {
    return wrapPlatformErrors(
      () => _hostApi.start(
        processIds,
        [for (final session in transcribers) session.channelInstanceId],
        [for (final session in turnDetectors) session.channelInstanceId],
        [for (final stream in vadStreams) stream.channelInstanceId],
        emitFrames,
      ),
    );
  }

  Future<void> stop() => wrapPlatformErrors(() => _hostApi.stop());

  Future<bool> get isRunning => wrapPlatformErrors(() => _hostApi.isRunning());

  /// Captured frames (only emitted while running with `emitFrames: true`).
  Stream<FluidMicFrame> get frames => _events.systemAudioFrames.map(
        (frame) => FluidMicFrame(samples: bytesToFloats(frame.samples), rms: frame.rms),
      );
}
