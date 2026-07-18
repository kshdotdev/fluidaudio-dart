import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'native_finalizer.dart';
import 'types.dart';

/// Voice activity detection (Silero, CoreML).
class FluidVad {
  FluidVad._(this._hostApi, this._instanceId, this._events) {
    final api = _hostApi;
    final id = _instanceId;
    nativeDisposeFinalizer.attach(this, finalizerDispose(() => api.dispose(id)), detach: this);
  }

  final messages.VadHostApi _hostApi;
  final int _instanceId;
  final FluidEventHub _events;
  bool _disposed = false;

  /// Loads the VAD model (≈1 MB; auto-downloads on first use).
  static Future<FluidVad> create({
    double threshold = 0.85,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.VadHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.VadHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(() => api.create(threshold, token));
      return FluidVad._(api, id, hub);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Runs VAD over [samples] (16 kHz mono float32) in 4096-sample chunks;
  /// returns one result per chunk.
  Future<List<FluidVadResult>> process(Float32List samples) async {
    _checkNotDisposed();
    final results = await wrapPlatformErrors(
        () => _hostApi.processSamples(_instanceId, floatsToBytes(samples)));
    return results.map(mapVadResult).toList();
  }

  /// Opens a streaming session emitting per-chunk ticks and
  /// speech-start/speech-end events.
  ///
  /// [minSilenceDuration] controls how much silence closes a speech segment.
  /// (FluidAudio's streaming state machine has no min-speech gate, so no
  /// such knob is exposed here.)
  Future<FluidVadStream> stream({double? minSilenceDuration}) async {
    _checkNotDisposed();
    final streamId = await wrapPlatformErrors(
        () => _hostApi.createStream(_instanceId, minSilenceDuration));
    return FluidVadStream._(_hostApi, streamId, _events);
  }

  /// Releases the VAD instance.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    nativeDisposeFinalizer.detach(this);
    await wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidVad was disposed');
    }
  }
}

/// A live VAD stream; feed 4096-sample chunks and listen to [events].
class FluidVadStream {
  FluidVadStream._(this._hostApi, this._streamId, this._events) {
    final api = _hostApi;
    final id = _streamId;
    nativeDisposeFinalizer.attach(this, finalizerDispose(() => api.disposeStream(id)), detach: this);
  }

  final messages.VadHostApi _hostApi;
  final int _streamId;
  final FluidEventHub _events;
  bool _disposed = false;

  /// Number of samples per [feed] chunk (256 ms at 16 kHz).
  static const int chunkSize = 4096;

  /// Channel-visible stream id, used by [FluidMicrophone] attachments.
  @internal
  int get channelInstanceId => _streamId;

  Stream<FluidVadStreamEvent> get events => _events.vadEventsFor(_streamId);

  /// Feeds one chunk of [chunkSize] 16 kHz mono float32 samples. Chunks are
  /// processed strictly in call order.
  Future<void> feed(Float32List chunk) {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.feedStream(_streamId, floatsToBytes(chunk)));
  }

  /// Resets segmentation state.
  Future<void> reset() {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.resetStream(_streamId));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    nativeDisposeFinalizer.detach(this);
    await wrapPlatformErrors(() => _hostApi.disposeStream(_streamId));
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidVadStream was disposed');
    }
  }
}
