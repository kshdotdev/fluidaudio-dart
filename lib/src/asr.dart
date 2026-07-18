import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'types.dart';

/// Batch speech-to-text (Parakeet TDT).
///
/// One-shot calls are stateless: a fresh native decoder state is created per
/// transcription, so results never leak between calls.
class FluidAsr {
  FluidAsr._(this._hostApi, this._instanceId);

  final messages.AsrHostApi _hostApi;
  final int _instanceId;
  bool _disposed = false;

  /// Downloads (if needed) and loads the Parakeet models.
  ///
  /// [onProgress] receives download/compile progress; loading from a warm
  /// cache emits little or nothing before completing.
  static Future<FluidAsr> load({
    AsrVersion version = AsrVersion.v3,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.AsrHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.AsrHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(
          () => api.load(messages.AsrVersionMessage.values[version.index], token));
      return FluidAsr._(api, id);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Transcribes 16 kHz mono float32 [samples].
  ///
  /// [language] is an ISO 639-1 code (e.g. `"en"`); v3 models are
  /// multilingual, v2 is English-only.
  Future<FluidAsrResult> transcribe(Float32List samples, {String? language}) async {
    _checkNotDisposed();
    final result = await wrapPlatformErrors(
        () => _hostApi.transcribeSamples(_instanceId, floatsToBytes(samples), language));
    return mapAsrResult(result);
  }

  /// Transcribes an audio file (wav/m4a/...); FluidAudio resamples internally
  /// and uses disk-backed processing for long files.
  Future<FluidAsrResult> transcribeFile(String path, {String? language}) async {
    _checkNotDisposed();
    final result = await wrapPlatformErrors(
        () => _hostApi.transcribeFile(_instanceId, path, language));
    return mapAsrResult(result);
  }

  /// Releases the native models. The instance is unusable afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidAsr was disposed');
    }
  }
}
