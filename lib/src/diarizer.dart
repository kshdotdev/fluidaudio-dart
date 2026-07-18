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

/// Offline speaker diarization (VBx pipeline, CoreML).
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
  Future<FluidDiarizationResult> diarize(Float32List samples) async {
    _checkNotDisposed();
    final result = await wrapPlatformErrors(
        () => _hostApi.diarizeSamples(_instanceId, floatsToBytes(samples)));
    return _mapResult(result);
  }

  /// Diarizes an audio file (resampled internally; disk-backed for long files).
  Future<FluidDiarizationResult> diarizeFile(String path) async {
    _checkNotDisposed();
    final result = await wrapPlatformErrors(() => _hostApi.diarizeFile(_instanceId, path));
    return _mapResult(result);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    nativeDisposeFinalizer.detach(this);
    await wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
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
