import 'dart:typed_data';

/// Parakeet model generation.
enum AsrVersion { v2, v3 }

/// Downloadable model bundles.
enum ModelKind {
  vad,
  parakeetV2,
  parakeetV3,

  /// The end-of-utterance streaming model (~450 MB), `ms320` chunk variant —
  /// the default a `FluidEou.create` session loads. Pre-download it so live
  /// turn detection can start without blocking on the network. `remove` clears
  /// every chunk variant of the EOU cache, not just `ms320`.
  eou,
}

/// Phase of a model download.
enum DownloadPhase { listing, downloading, compiling, completed, failed }

/// Audio source for a streaming session.
enum FluidAudioSource { microphone, system }

class FluidTokenTiming {
  const FluidTokenTiming({
    required this.token,
    required this.tokenId,
    required this.start,
    required this.end,
    required this.confidence,
  });

  final String token;
  final int tokenId;
  final Duration start;
  final Duration end;
  final double confidence;
}

class FluidAsrResult {
  const FluidAsrResult({
    required this.text,
    required this.confidence,
    required this.duration,
    required this.processingTime,
    this.tokenTimings,
  });

  final String text;
  final double confidence;

  /// Length of the transcribed audio.
  final Duration duration;

  final Duration processingTime;
  final List<FluidTokenTiming>? tokenTimings;

  /// Real-time factor: how many times faster than real time the audio was
  /// processed.
  double get rtfx => processingTime.inMicroseconds == 0
      ? 0
      : duration.inMicroseconds / processingTime.inMicroseconds;
}

class FluidTranscriptionUpdate {
  const FluidTranscriptionUpdate({
    required this.text,
    required this.isConfirmed,
    required this.confidence,
    this.tokenTimings,
  });

  final String text;

  /// Confirmed text is final; unconfirmed (volatile) text may be replaced by
  /// later updates.
  final bool isConfirmed;

  final double confidence;
  final List<FluidTokenTiming>? tokenTimings;
}

class FluidDownloadProgress {
  const FluidDownloadProgress({
    required this.fraction,
    required this.phase,
    this.completedFiles,
    this.totalFiles,
    this.modelName,
    this.errorMessage,
  });

  /// 0.0 – 1.0.
  final double fraction;
  final DownloadPhase phase;
  final int? completedFiles;
  final int? totalFiles;

  /// Model being compiled (phase == compiling).
  final String? modelName;

  /// Present when phase == failed.
  final String? errorMessage;
}

class FluidVadResult {
  const FluidVadResult({
    required this.probability,
    required this.isVoiceActive,
    required this.processingTime,
  });

  final double probability;
  final bool isVoiceActive;
  final Duration processingTime;
}

/// Per-chunk tick from a VAD stream. [isSpeechStart]/[isSpeechEnd] are both
/// false for plain probability ticks.
class FluidVadStreamEvent {
  const FluidVadStreamEvent({
    required this.probability,
    required this.isSpeechStart,
    required this.isSpeechEnd,
    this.sampleIndex,
    this.time,
  });

  final double probability;
  final bool isSpeechStart;
  final bool isSpeechEnd;
  final int? sampleIndex;
  final Duration? time;
}

/// Streaming ASR tuning knobs; unset fields use FluidAudio's `.streaming`
/// preset values.
class FluidStreamingConfig {
  const FluidStreamingConfig({
    this.chunkSeconds,
    this.hypothesisChunkSeconds,
    this.leftContextSeconds,
    this.rightContextSeconds,
    this.minContextForConfirmation,
    this.confirmationThreshold,
  });

  final double? chunkSeconds;
  final double? hypothesisChunkSeconds;
  final double? leftContextSeconds;
  final double? rightContextSeconds;
  final double? minContextForConfirmation;
  final double? confirmationThreshold;
}

/// Signature for audio delivered as 16 kHz mono float32 samples.
typedef AudioSamples = Float32List;

Duration durationFromSeconds(double seconds) =>
    Duration(microseconds: (seconds * 1e6).round());
