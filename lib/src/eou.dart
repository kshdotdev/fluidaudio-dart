import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'native_finalizer.dart';
import 'types.dart';

/// EOU model chunk size (latency/accuracy trade-off).
enum EouChunkSize { ms160, ms320, ms1280 }

/// Streaming end-of-utterance turn detection with live transcription.
///
/// Feed 16 kHz mono float32 chunks; [partials] emits ghost text as it forms,
/// [utterances] fires once per detected end-of-utterance with the utterance
/// transcript.
class FluidEou {
  FluidEou._(this._hostApi, this._instanceId, this._events) {
    final api = _hostApi;
    final id = _instanceId;
    nativeDisposeFinalizer.attach(this, finalizerDispose(() => api.dispose(id)), detach: this);
  }

  final messages.EouHostApi _hostApi;
  final int _instanceId;
  final FluidEventHub _events;
  bool _disposed = false;

  /// Channel-visible instance id, used by [FluidMicrophone] attachments.
  @internal
  int get channelInstanceId => _instanceId;

  /// Loads the EOU model (auto-downloads on first use; ~450 MB).
  ///
  /// To avoid blocking a live session on that first download, pre-fetch with
  /// `FluidModels.download(ModelKind.eou)` (and probe with
  /// `FluidModels.isDownloaded`); a session then starts from cache.
  static Future<FluidEou> create({
    EouChunkSize chunkSize = EouChunkSize.ms320,
    int eouDebounceMs = 1280,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.EouHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.EouHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(
        () => api.create(
            messages.EouChunkSizeMessage.values[chunkSize.index], eouDebounceMs, token),
      );
      return FluidEou._(api, id, hub);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Partial (in-progress) transcripts.
  Stream<String> get partials => _events
      .eouEventsFor(_instanceId)
      .where((event) => !event.isUtteranceEnd)
      .map((event) => event.text);

  /// Fired once per detected end of utterance, with its transcript.
  Stream<String> get utterances => _events
      .eouEventsFor(_instanceId)
      .where((event) => event.isUtteranceEnd)
      .map((event) => event.text);

  /// Feeds 16 kHz mono float32 samples; processed strictly in call order.
  Future<void> feed(Float32List samples) {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.feed(_instanceId, floatsToBytes(samples)));
  }

  /// Flushes pending audio and returns the final transcript.
  Future<String> finish() {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.finish(_instanceId));
  }

  Future<void> reset() {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.reset(_instanceId));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    nativeDisposeFinalizer.detach(this);
    await wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidEou was disposed');
    }
  }
}
