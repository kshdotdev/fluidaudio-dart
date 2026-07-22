import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'capture_health.dart';
import 'eou.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'streaming_asr.dart';
import 'vad.dart';

/// A captured microphone frame (16 kHz mono), for level meters/waveform UI.
class FluidMicFrame {
  const FluidMicFrame({required this.samples, required this.rms});

  final Float32List samples;

  /// Root-mean-square level of the frame.
  final double rms;
}

/// Native microphone capture.
///
/// Audio is captured with AVAudioEngine, resampled to 16 kHz mono natively,
/// and fanned out directly to the attached sessions — it never crosses the
/// platform channel (enable [FluidMicrophone.start]'s `emitFrames` to also
/// receive frames in Dart for UI).
///
/// One capture runs at a time. Requires the microphone permission
/// (`NSMicrophoneUsageDescription`, and the `com.apple.security.device.audio-input`
/// entitlement in sandboxed macOS apps).
class FluidMicrophone {
  FluidMicrophone({
    @visibleForTesting messages.MicrophoneHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  })  : _hostApi = hostApi ?? messages.MicrophoneHostApi(),
        _events = events ?? FluidEventHub.instance;

  final messages.MicrophoneHostApi _hostApi;
  final FluidEventHub _events;

  /// Starts capture, feeding the given sessions natively:
  /// [transcribers] receive the stream as `streamAudio`, [turnDetectors] as
  /// EOU processing, [vadStreams] as exact 4096-sample chunks.
  ///
  /// A non-null [recordToWavPath] additionally tees the capture into a WAV
  /// file at that path — written natively on the capture queue, so audio
  /// still never crosses the platform channel, and recording coexists with
  /// every live attachment. Pure sink semantics: it never starts or stops the
  /// capture, and the file is finalized on [stop]. The written stream is the
  /// ASR-grade 16 kHz mono pipeline (16-bit PCM WAV); archival fidelity would
  /// need a pre-resample tap, which this library does not provide. Naming,
  /// rotation and retention are the caller's concern.
  Future<void> start({
    List<FluidStreamingAsr> transcribers = const [],
    List<FluidEou> turnDetectors = const [],
    List<FluidVadStream> vadStreams = const [],
    bool emitFrames = false,
    String? recordToWavPath,
  }) {
    return wrapPlatformErrors(
      () => _hostApi.start(
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
  Stream<FluidMicFrame> get frames => _events.micFrames.map(
        (frame) => FluidMicFrame(samples: bytesToFloats(frame.samples), rms: frame.rms),
      );

  /// Watchdog phase transitions: after [start], a ~2 s self-test resolves to
  /// [CaptureHealthPhase.healthy] or an informational
  /// [CaptureHealthPhase.silent] (mic muted / device unavailable).
  Stream<FluidCaptureHealth> get health => _events
      .captureHealthFor(messages.CaptureSourceMessage.microphone)
      .map(mapCaptureHealth);
}
