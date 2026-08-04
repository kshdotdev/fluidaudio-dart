import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'native_finalizer.dart';
import 'types.dart';

/// Batch speech-to-text (Parakeet TDT).
///
/// One-shot calls are stateless: a fresh native decoder state is created per
/// transcription, so results never leak between calls.
class FluidAsr {
  FluidAsr._(this._hostApi, this._instanceId) {
    final api = _hostApi;
    final id = _instanceId;
    nativeDisposeFinalizer.attach(this, finalizerDispose(() => api.dispose(id)), detach: this);
  }

  final messages.AsrHostApi _hostApi;
  final int _instanceId;
  bool _disposed = false;
  int _nextOperationId = 1;
  Future<void>? _disposeFuture;

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
  ///
  /// For an operation that can be cancelled while native inference is in
  /// progress, use [startTranscription].
  Future<FluidAsrResult> transcribe(Float32List samples, {String? language}) =>
      startTranscription(samples, language: language).result;

  /// Starts a cancellable transcription of 16 kHz mono float32 [samples].
  ///
  /// The native inference task starts immediately. Calling
  /// [FluidAsrTranscription.cancel] requests cooperative cancellation and
  /// waits until that task has unwound. Its [FluidAsrTranscription.result]
  /// then completes with [FluidOperationCancelledException].
  FluidAsrTranscription startTranscription(Float32List samples, {String? language}) {
    _checkNotDisposed();
    final operationId = _allocateOperationId();
    final result = wrapPlatformErrors(() => _hostApi.transcribeSamples(
        _instanceId, operationId, floatsToBytes(samples), language)).then(mapAsrResult);
    return FluidAsrTranscription._(
      operationId: operationId,
      result: result,
      cancel: () => wrapPlatformErrors(() => _hostApi.cancel(_instanceId, operationId)),
    );
  }

  /// Transcribes an audio file (wav/m4a/...); FluidAudio resamples internally
  /// and uses disk-backed processing for long files.
  ///
  /// For an operation that can be cancelled while native inference is in
  /// progress, use [startFileTranscription].
  Future<FluidAsrResult> transcribeFile(String path, {String? language}) =>
      startFileTranscription(path, language: language).result;

  /// Starts a cancellable transcription of an audio file.
  ///
  /// FluidAudio resamples supported file formats internally and uses
  /// disk-backed processing for long files.
  FluidAsrTranscription startFileTranscription(String path, {String? language}) {
    _checkNotDisposed();
    final operationId = _allocateOperationId();
    final result = wrapPlatformErrors(
        () => _hostApi.transcribeFile(_instanceId, operationId, path, language)).then(mapAsrResult);
    return FluidAsrTranscription._(
      operationId: operationId,
      result: result,
      cancel: () => wrapPlatformErrors(() => _hostApi.cancel(_instanceId, operationId)),
    );
  }

  /// Cancels active transcriptions, then releases the native models.
  ///
  /// The instance is unusable as soon as disposal begins. Concurrent and
  /// repeated calls share the same completion.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    nativeDisposeFinalizer.detach(this);
    final future = wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
    _disposeFuture = future;
    return future;
  }

  int _allocateOperationId() {
    final id = _nextOperationId;
    _nextOperationId += 1;
    return id;
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidAsr was disposed');
    }
  }
}

/// A running one-shot ASR operation.
///
/// The operation belongs to the [FluidAsr] that created it. Cancellation is
/// idempotent and does not dispose that recognizer, so later operations can
/// still use its loaded models.
final class FluidAsrTranscription {
  FluidAsrTranscription._({
    required this.operationId,
    required this.result,
    required Future<void> Function() cancel,
  }) : _requestCancel = cancel;

  /// Caller-visible identity carried through the native channel boundary.
  final int operationId;

  /// The transcription result, or a
  /// [FluidOperationCancelledException] after cancellation.
  final Future<FluidAsrResult> result;

  final Future<void> Function() _requestCancel;
  Future<void>? _cancellation;

  /// Whether [cancel] has been called for this operation.
  bool get isCancellationRequested => _cancellation != null;

  /// Requests cooperative native cancellation and waits for inference to stop.
  ///
  /// Repeated calls share the same completion. Calling this after the operation
  /// has already finished is a successful no-op.
  Future<void> cancel() {
    final existing = _cancellation;
    if (existing != null) return existing;
    final future = _requestCancel();
    _cancellation = future;
    return future;
  }
}
