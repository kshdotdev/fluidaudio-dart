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

  /// Enables custom-vocabulary boosting with a vocabulary created via
  /// [CtcVocabularyHostApi.load]. Must be called before [start].
  @async
  void configureVocabulary(int instanceId, int vocabularyId);

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
  /// (Only [minSilenceDuration] applies: the streaming state machine has no
  /// min-speech gate in FluidAudio 0.15.x.)
  @async
  int createStream(int instanceId, double? minSilenceDuration);

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

// ---------------------------------------------------------------------------
// M2: offline diarization, EOU turn detection
// ---------------------------------------------------------------------------

/// EOU model chunk sizes (latency/accuracy trade-off).
enum EouChunkSizeMessage { ms160, ms320, ms1280 }

class DiarizationSegmentMessage {
  DiarizationSegmentMessage({
    required this.speakerId,
    required this.startSeconds,
    required this.endSeconds,
    required this.qualityScore,
    required this.embedding,
  });

  String speakerId;
  double startSeconds;
  double endSeconds;
  double qualityScore;

  /// Speaker embedding as float32 bytes.
  Uint8List embedding;
}

class SpeakerEmbeddingMessage {
  SpeakerEmbeddingMessage({required this.speakerId, required this.embedding});

  String speakerId;

  /// Float32 bytes.
  Uint8List embedding;
}

class ChunkEmbeddingMessage {
  ChunkEmbeddingMessage({
    required this.speakerId,
    required this.chunkIndex,
    required this.speakerIndex,
    required this.startSeconds,
    required this.endSeconds,
    required this.embedding256,
    required this.rho128,
  });

  String speakerId;
  int chunkIndex;
  int speakerIndex;
  double startSeconds;
  double endSeconds;

  /// L2-normalized embedding as float32 bytes.
  Uint8List embedding256;

  /// PLDA-whitened vector as float64 bytes (empty when unavailable).
  Uint8List rho128;
}

class DiarizationTimingsMessage {
  DiarizationTimingsMessage({
    required this.segmentationSeconds,
    required this.embeddingExtractionSeconds,
    required this.speakerClusteringSeconds,
    required this.postProcessingSeconds,
    required this.totalInferenceSeconds,
    required this.totalProcessingSeconds,
  });

  double segmentationSeconds;
  double embeddingExtractionSeconds;
  double speakerClusteringSeconds;
  double postProcessingSeconds;
  double totalInferenceSeconds;
  double totalProcessingSeconds;
}

class DiarizationResultMessage {
  DiarizationResultMessage({
    required this.segments,
    this.speakerDatabase,
    this.chunkEmbeddings,
    this.timings,
  });

  List<DiarizationSegmentMessage> segments;
  List<SpeakerEmbeddingMessage>? speakerDatabase;
  List<ChunkEmbeddingMessage>? chunkEmbeddings;
  DiarizationTimingsMessage? timings;
}

/// Per-chunk progress of a running diarization, tagged with the instance id.
class DiarizationProgressMessage {
  DiarizationProgressMessage({
    required this.instanceId,
    required this.processedChunks,
    required this.totalChunks,
  });

  int instanceId;
  int processedChunks;
  int totalChunks;
}

/// EOU stream event: a partial transcript or a completed utterance.
class EouEventMessage {
  EouEventMessage({
    required this.instanceId,
    required this.isUtteranceEnd,
    required this.text,
  });

  int instanceId;
  bool isUtteranceEnd;
  String text;
}

@HostApi()
abstract class DiarizerHostApi {
  /// Loads diarizer models (progress tagged with [progressToken]); returns an
  /// instance id. Speaker-count knobs mirror FluidAudio's clustering config.
  @async
  int create(
    double clusteringThreshold,
    int? numSpeakers,
    int? minSpeakers,
    int? maxSpeakers,
    bool exposeChunkEmbeddings,
    int progressToken,
  );

  /// Diarizes 16 kHz mono float32 samples. Per-chunk progress arrives on the
  /// `diarizationProgress` stream tagged with the instance id.
  @async
  DiarizationResultMessage diarizeSamples(int instanceId, Uint8List float32Samples);

  @async
  DiarizationResultMessage diarizeFile(int instanceId, String path);

  @async
  void dispose(int instanceId);
}

@HostApi()
abstract class EouHostApi {
  /// Creates an end-of-utterance streaming session (models load/download
  /// first; progress tagged with [progressToken]). Partial transcripts and
  /// utterance-end events arrive on `eouEvents` tagged with the returned id.
  @async
  int create(EouChunkSizeMessage chunkSize, int eouDebounceMs, int progressToken);

  /// Feeds 16 kHz mono float32 samples; processed strictly in call order.
  @async
  void feed(int instanceId, Uint8List float32Samples);

  /// Flushes and returns the final transcript.
  @async
  String finish(int instanceId);

  @async
  void reset(int instanceId);

  @async
  void dispose(int instanceId);
}

// ---------------------------------------------------------------------------
// M3: CTC custom vocabulary, inverse text normalization
// (Qwen3 was removed upstream in FluidAudio 0.15.x and is not bound.)
// ---------------------------------------------------------------------------

class VocabularyTermMessage {
  VocabularyTermMessage({required this.text, this.weight, this.aliases});

  String text;
  double? weight;
  List<String>? aliases;
}

@HostApi()
abstract class CtcVocabularyHostApi {
  /// Downloads/loads the CTC-110M spotter models, tokenizes [terms], and
  /// returns a vocabulary instance id for use with
  /// [StreamingAsrHostApi.configureVocabulary].
  @async
  int load(List<VocabularyTermMessage> terms, double minSimilarity, int progressToken);

  @async
  void dispose(int instanceId);
}

@HostApi()
abstract class ItnHostApi {
  /// Whether the native NeMo normalization library is loadable; when false
  /// all normalization calls are no-ops returning the input unchanged.
  @async
  bool isNativeAvailable();

  /// Normalizes a single spoken-form expression to written form.
  @async
  String normalize(String text);

  /// Sliding-window normalization across a full sentence.
  @async
  String normalizeSentence(String text, int? maxSpanTokens);

  @async
  void addRule(String spoken, String written);

  @async
  bool removeRule(String spoken);

  @async
  void clearRules();
}

// ---------------------------------------------------------------------------
// M4: text-to-speech (Kokoro ANE, PocketTTS), audio conversion
// ---------------------------------------------------------------------------

enum KokoroVariantMessage { english, mandarin, japanese }

class TtsResultMessage {
  TtsResultMessage({
    required this.samples,
    required this.sampleRate,
    required this.wav,
  });

  /// Raw float32 PCM bytes (24 kHz mono).
  Uint8List samples;
  int sampleRate;

  /// WAV-encoded 16-bit PCM, ready for playback or writing to disk.
  Uint8List wav;
}

/// One streamed synthesis frame (80 ms at 24 kHz), tagged with the caller's
/// stream token so concurrent syntheses never interleave.
class TtsChunkMessage {
  TtsChunkMessage({
    required this.streamToken,
    required this.samples,
    required this.frameIndex,
    required this.chunkIndex,
    required this.chunkCount,
    required this.isLast,
  });

  int streamToken;

  /// Float32 PCM bytes (empty on the [isLast] sentinel).
  Uint8List samples;
  int frameIndex;
  int chunkIndex;
  int chunkCount;

  /// End-of-stream sentinel: emitted after the final frame, in order on the
  /// same channel, so the Dart stream closes without cross-channel races.
  bool isLast;
}

@HostApi()
abstract class TtsHostApi {
  /// Downloads/loads Kokoro-ANE models (progress tagged with
  /// [progressToken]); returns an instance id.
  @async
  int kokoroCreate(KokoroVariantMessage variant, String? defaultVoice, int progressToken);

  /// Synthesizes to WAV bytes (24 kHz mono 16-bit).
  @async
  Uint8List kokoroSynthesizeWav(int instanceId, String text, String? voice, double speed);

  @async
  TtsResultMessage kokoroSynthesizeDetailed(
      int instanceId, String text, String? voice, double speed);

  /// Downloads/loads PocketTTS models; returns an instance id.
  @async
  int pocketCreate(String? defaultVoice, int progressToken);

  @async
  Uint8List pocketSynthesizeWav(int instanceId, String text, String? voice, double temperature);

  /// Streams synthesis frames on the `ttsChunks` channel tagged with the
  /// caller-chosen [streamToken]; an `isLast` sentinel closes the stream.
  @async
  void pocketSynthesizeStreaming(
      int instanceId, String text, String? voice, double temperature, int streamToken);

  /// Clones a voice from 1-10 s of 24 kHz mono float32 audio; returns a
  /// voice id usable with [pocketSynthesizeWithVoice].
  @async
  int pocketCloneVoice(int instanceId, Uint8List float32Samples24k);

  @async
  Uint8List pocketSynthesizeWithVoice(
      int instanceId, int voiceId, String text, double temperature);

  @async
  void dispose(int instanceId);
}

@HostApi()
abstract class AudioHostApi {
  /// Decodes and resamples any audio file to 16 kHz mono float32 bytes.
  @async
  Uint8List resampleFile(String path);

  /// Resamples float32 samples from [fromRate] to 16 kHz mono.
  @async
  Uint8List resample(Uint8List float32Samples, double fromRate);

  /// Encodes float32 samples as a 16-bit PCM WAV file.
  @async
  Uint8List encodeWav(Uint8List float32Samples, double sampleRate);
}

// ---------------------------------------------------------------------------
// M5: native microphone capture
// ---------------------------------------------------------------------------

/// A captured microphone frame (16 kHz mono), emitted when frame emission is
/// enabled — for waveform/level UI, not for round-tripping audio.
class MicFrameMessage {
  MicFrameMessage({required this.samples, required this.rms});

  /// Float32 PCM bytes at 16 kHz mono.
  Uint8List samples;

  /// Root-mean-square level of this frame (0..1-ish), for level meters.
  double rms;
}

@HostApi()
abstract class MicrophoneHostApi {
  /// Starts microphone capture and fans the 16 kHz mono stream out natively
  /// to the given sessions (no audio crosses the platform channel):
  /// streaming-ASR sessions get `streamAudio`, EOU sessions get `process`,
  /// VAD streams get exact 4096-sample chunks. With [emitFrames], frames are
  /// also published on the `micFrames` stream for UI.
  @async
  void start(
    List<int> asrInstanceIds,
    List<int> eouInstanceIds,
    List<int> vadStreamIds,
    bool emitFrames,
  );

  @async
  void stop();

  @async
  bool isRunning();
}

// ---------------------------------------------------------------------------
// M6: system-audio capture (macOS 14.4+ Core Audio process taps)
// ---------------------------------------------------------------------------

enum CaptureSourceMessage { microphone, systemAudio }

/// Watchdog phase of a running capture.
enum CaptureHealthPhaseMessage {
  /// Self-test window after start (~2 s).
  validating,

  /// Audio with real content is flowing.
  healthy,

  /// The system tap was silent; rebuilding it once with fresh process
  /// translation (helpers often become tappable only after opening audio).
  rebuilding,

  /// Callbacks fire but every frame is zero. For the microphone this is
  /// informational (probably muted); for system audio it follows a failed
  /// rebuild.
  silent,

  /// The capture produced no audio and the rebuild did not recover it.
  failed,
}

/// Capture watchdog event, emitted on phase transitions.
class CaptureHealthMessage {
  CaptureHealthMessage({
    required this.source,
    required this.phase,
    required this.callbackCount,
    required this.receivingAudio,
    this.detail,
  });

  CaptureSourceMessage source;
  CaptureHealthPhaseMessage phase;

  /// Device callbacks observed since start/rebuild.
  int callbackCount;

  /// Whether any non-zero frame has been observed.
  bool receivingAudio;

  String? detail;
}

/// A process currently known to Core Audio (candidate for a targeted tap).
class AudioProcessMessage {
  AudioProcessMessage({
    required this.pid,
    required this.bundleId,
    required this.isPlayingAudio,
  });

  int pid;
  String bundleId;

  /// Whether the process currently has running audio output.
  bool isPlayingAudio;
}

@HostApi()
abstract class SystemAudioHostApi {
  /// Whether process-tap capture is available (macOS 14.4+; always false on
  /// iOS).
  @async
  bool isSupported();

  /// Lists processes known to Core Audio (reading this metadata needs no
  /// permission — only tapping audio content does). Use the PIDs with
  /// [start]'s processIds to tap one application.
  @async
  List<AudioProcessMessage> listAudioProcesses();

  /// Preflights the "System Audio Recording" permission by creating a
  /// throwaway tap. Returns true when tapping is allowed; on first call the
  /// OS shows the TCC prompt (there is no direct request API).
  @async
  bool requestPermission();

  /// Starts capturing system audio — all processes except this one when
  /// [processIds] is empty, otherwise only the given PIDs — and fans the
  /// 16 kHz mono stream out natively to the given sessions, exactly like
  /// [MicrophoneHostApi.start].
  @async
  void start(
    List<int> processIds,
    List<int> asrInstanceIds,
    List<int> eouInstanceIds,
    List<int> vadStreamIds,
    bool emitFrames,
  );

  @async
  void stop();

  @async
  bool isRunning();
}

@EventChannelApi()
abstract class FluidAudioEventChannelApi {
  DebugEventMessage debugEvents();
  TranscriptionUpdateMessage transcriptionUpdates();
  DownloadProgressMessage downloadProgress();
  VadStreamEventMessage vadEvents();
  DiarizationProgressMessage diarizationProgress();
  EouEventMessage eouEvents();
  TtsChunkMessage ttsChunks();
  MicFrameMessage micFrames();

  /// Captured system-audio frames (16 kHz mono), when frame emission is on.
  MicFrameMessage systemAudioFrames();

  /// Capture watchdog phase transitions for mic and system audio.
  CaptureHealthMessage captureHealth();
}
