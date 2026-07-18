import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'native_finalizer.dart';
import 'types.dart';

/// Kokoro voice-model variants.
enum KokoroVariant { english, mandarin, japanese }

/// Detailed synthesis output: raw samples plus a ready-to-play WAV.
class FluidTtsResult {
  const FluidTtsResult({
    required this.samples,
    required this.sampleRate,
    required this.wav,
  });

  /// Raw float32 PCM (24 kHz mono).
  final Float32List samples;
  final int sampleRate;

  /// WAV-encoded 16-bit PCM.
  final Uint8List wav;

  Duration get duration =>
      Duration(microseconds: (samples.length / sampleRate * 1e6).round());
}

/// One streamed synthesis frame (80 ms at 24 kHz).
class FluidTtsChunk {
  const FluidTtsChunk({
    required this.samples,
    required this.frameIndex,
    required this.chunkIndex,
    required this.chunkCount,
  });

  final Float32List samples;
  final int frameIndex;
  final int chunkIndex;
  final int chunkCount;
}

/// A voice cloned from reference audio, usable with
/// [FluidPocketTts.synthesizeWithVoice].
class FluidPocketVoice {
  const FluidPocketVoice._(this.voiceId);

  final int voiceId;
}

/// Kokoro text-to-speech on the Apple Neural Engine (24 kHz output).
///
/// Voices are identifier strings (English default `af_heart`); additional
/// voices download on demand.
class FluidKokoroTts {
  FluidKokoroTts._(this._hostApi, this._instanceId) {
    final api = _hostApi;
    final id = _instanceId;
    nativeDisposeFinalizer.attach(this, finalizerDispose(() => api.dispose(id)), detach: this);
  }

  final messages.TtsHostApi _hostApi;
  final int _instanceId;
  bool _disposed = false;

  static Future<FluidKokoroTts> create({
    KokoroVariant variant = KokoroVariant.english,
    String? defaultVoice,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.TtsHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.TtsHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(
        () => api.kokoroCreate(
            messages.KokoroVariantMessage.values[variant.index], defaultVoice, token),
      );
      return FluidKokoroTts._(api, id);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Synthesizes [text] to WAV bytes (24 kHz mono 16-bit).
  Future<Uint8List> synthesizeWav(String text, {String? voice, double speed = 1.0}) {
    _checkNotDisposed();
    return wrapPlatformErrors(
        () => _hostApi.kokoroSynthesizeWav(_instanceId, text, voice, speed));
  }

  Future<FluidTtsResult> synthesizeDetailed(String text,
      {String? voice, double speed = 1.0}) async {
    _checkNotDisposed();
    final result = await wrapPlatformErrors(
        () => _hostApi.kokoroSynthesizeDetailed(_instanceId, text, voice, speed));
    return FluidTtsResult(
      samples: bytesToFloats(result.samples),
      sampleRate: result.sampleRate,
      wav: result.wav,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    nativeDisposeFinalizer.detach(this);
    await wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidKokoroTts was disposed');
    }
  }
}

/// PocketTTS: fast streaming text-to-speech with voice cloning (24 kHz).
class FluidPocketTts {
  FluidPocketTts._(this._hostApi, this._instanceId, this._events) {
    final api = _hostApi;
    final id = _instanceId;
    nativeDisposeFinalizer.attach(this, finalizerDispose(() => api.dispose(id)), detach: this);
  }

  final messages.TtsHostApi _hostApi;
  final int _instanceId;
  final FluidEventHub _events;
  bool _disposed = false;

  static Future<FluidPocketTts> create({
    String? defaultVoice,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.TtsHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.TtsHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(() => api.pocketCreate(defaultVoice, token));
      return FluidPocketTts._(api, id, hub);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Synthesizes [text] to WAV bytes (24 kHz mono 16-bit).
  Future<Uint8List> synthesizeWav(String text, {String? voice, double temperature = 0.7}) {
    _checkNotDisposed();
    return wrapPlatformErrors(
        () => _hostApi.pocketSynthesizeWav(_instanceId, text, voice, temperature));
  }

  /// Streams synthesis frames (80 ms each) as they are generated.
  ///
  /// Frames are tagged with a per-call token, so concurrent calls on the same
  /// instance never interleave. The stream closes on the native end-of-stream
  /// sentinel (ordered after the last frame on the same channel).
  Stream<FluidTtsChunk> synthesizeStreaming(String text,
      {String? voice, double temperature = 0.7}) {
    _checkNotDisposed();
    final streamToken = _events.allocateProgressToken();
    late StreamController<FluidTtsChunk> controller;
    StreamSubscription<messages.TtsChunkMessage>? subscription;

    Future<void> closeSafely() async {
      await subscription?.cancel();
      subscription = null;
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<FluidTtsChunk>(
      onListen: () {
        subscription = _events.ttsChunksFor(streamToken).listen((chunk) {
          if (controller.isClosed) return;
          if (chunk.isLast) {
            closeSafely();
            return;
          }
          controller.add(
            FluidTtsChunk(
              samples: bytesToFloats(chunk.samples),
              frameIndex: chunk.frameIndex,
              chunkIndex: chunk.chunkIndex,
              chunkCount: chunk.chunkCount,
            ),
          );
        });
        wrapPlatformErrors(() => _hostApi.pocketSynthesizeStreaming(
            _instanceId, text, voice, temperature, streamToken)).then(
          (_) {
            // Success closes via the isLast sentinel; this is only a backstop
            // in case the sentinel was lost (e.g. listener raced teardown).
            Future<void>.delayed(const Duration(seconds: 2), () {
              if (!controller.isClosed) closeSafely();
            });
          },
          onError: (Object error) {
            if (!controller.isClosed) controller.addError(error);
            closeSafely();
          },
        );
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// Clones a voice from 1-10 seconds of 24 kHz mono float32 audio.
  Future<FluidPocketVoice> cloneVoice(Float32List samples24k) async {
    _checkNotDisposed();
    final voiceId = await wrapPlatformErrors(
        () => _hostApi.pocketCloneVoice(_instanceId, floatsToBytes(samples24k)));
    return FluidPocketVoice._(voiceId);
  }

  /// Synthesizes with a previously cloned voice.
  Future<Uint8List> synthesizeWithVoice(String text, FluidPocketVoice voice,
      {double temperature = 0.7}) {
    _checkNotDisposed();
    return wrapPlatformErrors(() =>
        _hostApi.pocketSynthesizeWithVoice(_instanceId, voice.voiceId, text, temperature));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    nativeDisposeFinalizer.detach(this);
    await wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidPocketTts was disposed');
    }
  }
}
