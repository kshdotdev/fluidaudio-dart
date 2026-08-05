import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'native_finalizer.dart';
import 'types.dart';

/// A diarized speaker segment with its raw speaker embedding.
class FluidDiarizationSegment {
  const FluidDiarizationSegment({
    required this.speakerId,
    required this.start,
    required this.end,
    required this.qualityScore,
    required this.embedding,
  });

  /// Cluster label ("S1", "S2", …) — stable within one result, not across runs.
  final String speakerId;

  final Duration start;
  final Duration end;
  final double qualityScore;

  /// Raw speaker embedding — usable for cross-recording speaker identity.
  final Float32List embedding;

  Duration get duration => end - start;
}

class FluidSpeakerEmbedding {
  const FluidSpeakerEmbedding({required this.speakerId, required this.embedding});

  final String speakerId;
  final Float32List embedding;
}

class FluidChunkEmbedding {
  const FluidChunkEmbedding({
    required this.speakerId,
    required this.chunkIndex,
    required this.speakerIndex,
    required this.start,
    required this.end,
    required this.embedding256,
    required this.rho128,
  });

  final String speakerId;
  final int chunkIndex;
  final int speakerIndex;
  final Duration start;
  final Duration end;
  final Float32List embedding256;
  final Float64List rho128;
}

class FluidDiarizationTimings {
  const FluidDiarizationTimings({
    required this.segmentation,
    required this.embeddingExtraction,
    required this.speakerClustering,
    required this.postProcessing,
    required this.totalInference,
    required this.totalProcessing,
  });

  final Duration segmentation;
  final Duration embeddingExtraction;
  final Duration speakerClustering;
  final Duration postProcessing;
  final Duration totalInference;
  final Duration totalProcessing;
}

class FluidDiarizationResult {
  const FluidDiarizationResult({
    required this.segments,
    this.speakerDatabase,
    this.chunkEmbeddings,
    this.timings,
  });

  final List<FluidDiarizationSegment> segments;

  /// Speaker id → representative embedding.
  final List<FluidSpeakerEmbedding>? speakerDatabase;

  final List<FluidChunkEmbedding>? chunkEmbeddings;
  final FluidDiarizationTimings? timings;

  /// Distinct speakers found.
  Set<String> get speakerIds => {for (final segment in segments) segment.speakerId};
}

/// Offline (batch) speaker diarization, CoreML.
///
/// Wraps FluidAudio's `OfflineDiarizerManager`: pyannote community-1 powerset
/// segmentation → filterbank front-end → WeSpeaker embeddings → PLDA scoring →
/// VBx (variational Bayes) clustering. "VBx" names the clustering stage only,
/// not the pipeline; this is *not* the LS-EEND or Sortformer diarizer (both
/// exist upstream, neither is bound here — see the streaming-diarization note
/// in `doc/ARCHITECTURE.md`).
class FluidDiarizer {
  FluidDiarizer._(this._hostApi, this._instanceId, this._events) {
    final api = _hostApi;
    final id = _instanceId;
    nativeDisposeFinalizer.attach(this, finalizerDispose(() => api.dispose(id)), detach: this);
  }

  final messages.DiarizerHostApi _hostApi;
  final int _instanceId;
  final FluidEventHub _events;
  bool _disposed = false;
  int _nextOperationId = 1;
  Future<void>? _disposeFuture;

  /// Loads diarizer models (~20 MB; auto-downloads on first use).
  ///
  /// [numSpeakers] pins the exact speaker count; otherwise clustering is
  /// bounded by [minSpeakers]/[maxSpeakers] when given.
  static Future<FluidDiarizer> create({
    double clusteringThreshold = 0.6,
    int? numSpeakers,
    int? minSpeakers,
    int? maxSpeakers,
    bool exposeChunkEmbeddings = false,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.DiarizerHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.DiarizerHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(
        () => api.create(clusteringThreshold, numSpeakers, minSpeakers, maxSpeakers,
            exposeChunkEmbeddings, token),
      );
      return FluidDiarizer._(api, id, hub);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Per-chunk progress of running [diarize]/[diarizeFile] calls.
  Stream<(int processed, int total)> get progress =>
      _events.diarizationProgressFor(_instanceId);

  /// Diarizes 16 kHz mono float32 [samples].
  ///
  /// For an operation that can be cancelled while native inference is in
  /// progress, use [startDiarization].
  Future<FluidDiarizationResult> diarize(Float32List samples) =>
      startDiarization(samples).result;

  /// Starts cancellable diarization of 16 kHz mono float32 [samples].
  ///
  /// Calling [FluidDiarizationOperation.cancel] requests cooperative native
  /// cancellation and waits until FluidAudio's retained task has unwound.
  FluidDiarizationOperation startDiarization(Float32List samples) {
    _checkNotDisposed();
    final operationId = _allocateOperationId();
    final result = wrapPlatformErrors(
        () => _hostApi.diarizeSamples(_instanceId, operationId, floatsToBytes(samples)))
        .then(_mapResult);
    return FluidDiarizationOperation._(
      operationId: operationId,
      result: result,
      cancel: () => wrapPlatformErrors(() => _hostApi.cancel(_instanceId, operationId)),
    );
  }

  /// Diarizes an audio file (resampled internally; disk-backed for long files).
  ///
  /// For an operation that can be cancelled while native inference is in
  /// progress, use [startFileDiarization].
  Future<FluidDiarizationResult> diarizeFile(String path) =>
      startFileDiarization(path).result;

  /// Starts cancellable diarization of an audio file.
  ///
  /// FluidAudio resamples supported file formats internally and uses a
  /// disk-backed source for long files.
  FluidDiarizationOperation startFileDiarization(String path) {
    _checkNotDisposed();
    final operationId = _allocateOperationId();
    final result = wrapPlatformErrors(
        () => _hostApi.diarizeFile(_instanceId, operationId, path)).then(_mapResult);
    return FluidDiarizationOperation._(
      operationId: operationId,
      result: result,
      cancel: () => wrapPlatformErrors(() => _hostApi.cancel(_instanceId, operationId)),
    );
  }

  /// Cancels active diarizations, then releases the native models.
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
      throw StateError('FluidDiarizer was disposed');
    }
  }

  static FluidDiarizationResult _mapResult(messages.DiarizationResultMessage result) {
    return FluidDiarizationResult(
      segments: [
        for (final segment in result.segments)
          FluidDiarizationSegment(
            speakerId: segment.speakerId,
            start: durationFromSeconds(segment.startSeconds),
            end: durationFromSeconds(segment.endSeconds),
            qualityScore: segment.qualityScore,
            embedding: bytesToFloats(segment.embedding),
          ),
      ],
      speakerDatabase: result.speakerDatabase == null
          ? null
          : [
              for (final speaker in result.speakerDatabase!)
                FluidSpeakerEmbedding(
                  speakerId: speaker.speakerId,
                  embedding: bytesToFloats(speaker.embedding),
                ),
            ],
      chunkEmbeddings: result.chunkEmbeddings == null
          ? null
          : [
              for (final chunk in result.chunkEmbeddings!)
                FluidChunkEmbedding(
                  speakerId: chunk.speakerId,
                  chunkIndex: chunk.chunkIndex,
                  speakerIndex: chunk.speakerIndex,
                  start: durationFromSeconds(chunk.startSeconds),
                  end: durationFromSeconds(chunk.endSeconds),
                  embedding256: bytesToFloats(chunk.embedding256),
                  rho128: _bytesToDoubles(chunk.rho128),
                ),
            ],
      timings: result.timings == null
          ? null
          : FluidDiarizationTimings(
              segmentation: durationFromSeconds(result.timings!.segmentationSeconds),
              embeddingExtraction:
                  durationFromSeconds(result.timings!.embeddingExtractionSeconds),
              speakerClustering:
                  durationFromSeconds(result.timings!.speakerClusteringSeconds),
              postProcessing: durationFromSeconds(result.timings!.postProcessingSeconds),
              totalInference: durationFromSeconds(result.timings!.totalInferenceSeconds),
              totalProcessing: durationFromSeconds(result.timings!.totalProcessingSeconds),
            ),
    );
  }

  static Float64List _bytesToDoubles(Uint8List bytes) {
    if (bytes.offsetInBytes % Float64List.bytesPerElement == 0) {
      return bytes.buffer.asFloat64List(
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ Float64List.bytesPerElement,
      );
    }
    final aligned = Uint8List.fromList(bytes);
    return aligned.buffer
        .asFloat64List(0, aligned.lengthInBytes ~/ Float64List.bytesPerElement);
  }
}

/// A running offline diarization operation.
///
/// The operation belongs to the [FluidDiarizer] that created it. Cancellation
/// is idempotent and does not dispose that diarizer, so later operations can
/// reuse its loaded models.
final class FluidDiarizationOperation {
  FluidDiarizationOperation._({
    required this.operationId,
    required this.result,
    required Future<void> Function() cancel,
  }) : _requestCancel = cancel;

  /// Caller-visible identity carried through the native channel boundary.
  final int operationId;

  /// The diarization result, or a [FluidOperationCancelledException] after
  /// cancellation.
  final Future<FluidDiarizationResult> result;

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
