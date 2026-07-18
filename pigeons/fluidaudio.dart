// Pigeon schema for fluidaudio_dart.
//
// Regenerate with:
//   dart run pigeon --input pigeons/fluidaudio.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    swiftOut: 'darwin/fluidaudio_dart/Sources/fluidaudio_dart/Messages.g.swift',
    dartPackageName: 'fluidaudio_dart',
  ),
)
/// System information reported by the native FluidAudio runtime.
class SystemInfoMessage {
  SystemInfoMessage({
    required this.summary,
    required this.isAppleSilicon,
    required this.isIntelMac,
    required this.qwen3Supported,
  });

  /// Human-readable summary from FluidAudio's `SystemInfo.summary()`.
  String summary;

  bool isAppleSilicon;
  bool isIntelMac;

  /// Whether Qwen3 models can run on this OS (macOS 15+ / iOS 18+).
  bool qwen3Supported;
}

/// Diagnostic event used to validate the native → Dart event-channel bridge.
class DebugEventMessage {
  DebugEventMessage({required this.sequence, required this.message, this.payload});

  int sequence;
  String message;

  /// Optional typed-data payload (validates typed data inside event DTOs).
  ///
  /// Convention: little-endian float32 bytes. Pigeon has no Float32List type,
  /// so audio buffers cross the channel as Uint8List byte-views
  /// (`Float32List.view(bytes.buffer)` on the Dart side — no element copy).
  Uint8List? payload;
}

@HostApi()
abstract class SystemHostApi {
  @async
  SystemInfoMessage systemInfo();

  /// Round-trips a float32-bytes buffer across the channel (typed-data probe).
  @async
  Uint8List echoFloats(Uint8List samples);

  /// Emits [count] events on the `debugEvents` stream (event-channel probe).
  @async
  void debugEmitEvents(int count);
}

// ---------------------------------------------------------------------------
// M1: models, batch ASR, streaming ASR, VAD
// ---------------------------------------------------------------------------

/// Parakeet model generations exposed to Dart.
enum AsrVersionMessage { v2, v3 }

/// Downloadable model bundles (subset of FluidAudio's `Repo`; grows per milestone).
enum ModelKindMessage { vad, parakeetV2, parakeetV3 }

enum DownloadPhaseMessage { listing, downloading, compiling, completed, failed }

/// Audio source for a streaming session.
enum AudioSourceMessage { microphone, system }

class TokenTimingMessage {
  TokenTimingMessage({
    required this.token,
    required this.tokenId,
    required this.startSeconds,
    required this.endSeconds,
    required this.confidence,
  });

  String token;
  int tokenId;
  double startSeconds;
  double endSeconds;
  double confidence;
}

class AsrResultMessage {
  AsrResultMessage({
    required this.text,
    required this.confidence,
    required this.durationSeconds,
    required this.processingSeconds,
    this.tokenTimings,
  });

  String text;
  double confidence;
  double durationSeconds;
  double processingSeconds;
  List<TokenTimingMessage>? tokenTimings;
}

/// Streaming transcription update, tagged with the emitting session.
class TranscriptionUpdateMessage {
  TranscriptionUpdateMessage({
    required this.instanceId,
    required this.text,
    required this.isConfirmed,
    required this.confidence,
    this.tokenTimings,
  });

  int instanceId;
  String text;
  bool isConfirmed;
  double confidence;
  List<TokenTimingMessage>? tokenTimings;
}

/// Model download/compile progress, tagged with a caller-chosen token.
class DownloadProgressMessage {
  DownloadProgressMessage({
    required this.progressToken,
    required this.fraction,
    required this.phase,
    this.completedFiles,
    this.totalFiles,
    this.modelName,
    this.errorMessage,
  });

  int progressToken;
  double fraction;
  DownloadPhaseMessage phase;
  int? completedFiles;
  int? totalFiles;
  String? modelName;
  String? errorMessage;
}

class VadResultMessage {
  VadResultMessage({
    required this.probability,
    required this.isVoiceActive,
    required this.processingSeconds,
  });

  double probability;
  bool isVoiceActive;
  double processingSeconds;
}

/// Per-chunk VAD stream tick. [isSpeechStart]/[isSpeechEnd] are both false for
/// plain probability ticks with no segmentation event.
class VadStreamEventMessage {
  VadStreamEventMessage({
    required this.instanceId,
    required this.probability,
    required this.isSpeechStart,
    required this.isSpeechEnd,
    this.sampleIndex,
    this.timeSeconds,
  });

  int instanceId;
  double probability;
  bool isSpeechStart;
  bool isSpeechEnd;
  int? sampleIndex;
  double? timeSeconds;
}

@HostApi()
abstract class ModelsHostApi {
  @async
  bool isDownloaded(ModelKindMessage kind);

  /// Downloads [kind], reporting progress on the `downloadProgress` stream
  /// tagged with [progressToken]. Completes when the download finishes.
  @async
  void download(ModelKindMessage kind, int progressToken);

  @async
  void remove(ModelKindMessage kind);

  @async
  String cacheDirectory(ModelKindMessage kind);

  /// Process-global offline switch; must be set before any load/download.
  @async
  void setOfflineMode(bool enabled);
}

@HostApi()
abstract class AsrHostApi {
  /// Downloads (if needed) and loads Parakeet models; returns an instance id.
  /// Progress is reported on `downloadProgress` tagged with [progressToken].
  @async
  int load(AsrVersionMessage version, int progressToken);

  /// One-shot transcription of 16 kHz mono float32 samples (fresh decoder
  /// state per call). [languageCode] is an ISO 639-1 code such as "en".
  @async
  AsrResultMessage transcribeSamples(
      int instanceId, Uint8List float32Samples, String? languageCode);

  @async
  AsrResultMessage transcribeFile(int instanceId, String path, String? languageCode);

  @async
  void dispose(int instanceId);
}

class StreamingConfigMessage {
  StreamingConfigMessage({
    this.chunkSeconds,
    this.hypothesisChunkSeconds,
    this.leftContextSeconds,
    this.rightContextSeconds,
    this.minContextForConfirmation,
    this.confirmationThreshold,
  });

  double? chunkSeconds;
  double? hypothesisChunkSeconds;
  double? leftContextSeconds;
  double? rightContextSeconds;
  double? minContextForConfirmation;
  double? confirmationThreshold;
}

@HostApi()
abstract class StreamingAsrHostApi {
  /// Creates a sliding-window streaming session (models load/download first;
  /// progress tagged with [progressToken]). Updates arrive on the
  /// `transcriptionUpdates` stream tagged with the returned instance id.
  @async
  int create(AsrVersionMessage version, StreamingConfigMessage? config, int progressToken);

  @async
  void start(int instanceId, AudioSourceMessage source);

  /// Feeds 16 kHz mono float32 samples. Buffers are processed strictly in
  /// call order (serialized natively).
  @async
  void feed(int instanceId, Uint8List float32Samples);

  /// Flushes pending audio and returns the final transcript.
  @async
  String finish(int instanceId);

  @async
  void reset(int instanceId);

  @async
  void dispose(int instanceId);
}

@HostApi()
abstract class VadHostApi {
  /// Loads the Silero VAD (auto-downloads; progress tagged with
  /// [progressToken]); returns an instance id.
  @async
  int create(double threshold, int progressToken);

  @async
  List<VadResultMessage> processSamples(int instanceId, Uint8List float32Samples);

  /// Creates a streaming state on an existing VAD instance; events arrive on
  /// the `vadEvents` stream tagged with the returned stream id.
  @async
  int createStream(int instanceId, double? minSpeechDuration, double? minSilenceDuration);

  /// Feeds one 4096-sample chunk; processed strictly in call order.
  @async
  void feedStream(int streamId, Uint8List float32Chunk);

  @async
  void resetStream(int streamId);

  @async
  void disposeStream(int streamId);

  @async
  void dispose(int instanceId);
}

@EventChannelApi()
abstract class FluidAudioEventChannelApi {
  DebugEventMessage debugEvents();
  TranscriptionUpdateMessage transcriptionUpdates();
  DownloadProgressMessage downloadProgress();
  VadStreamEventMessage vadEvents();
}
