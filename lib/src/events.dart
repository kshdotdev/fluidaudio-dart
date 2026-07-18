import 'dart:async';

import 'package:meta/meta.dart';

import 'messages.g.dart' as messages;
import 'types.dart';

/// Shared broadcast views over the pigeon event channels.
///
/// An EventChannel supports a single native stream handler, so each channel is
/// subscribed once and demultiplexed here by instance id / progress token.
class FluidEventHub {
  FluidEventHub._();

  /// Test constructor with injected raw channel streams.
  @visibleForTesting
  FluidEventHub.test({
    Stream<messages.TranscriptionUpdateMessage>? transcriptionUpdates,
    Stream<messages.DownloadProgressMessage>? downloadProgress,
    Stream<messages.VadStreamEventMessage>? vadEvents,
    Stream<messages.DiarizationProgressMessage>? diarizationProgress,
    Stream<messages.EouEventMessage>? eouEvents,
    Stream<messages.TtsChunkMessage>? ttsChunks,
    Stream<messages.MicFrameMessage>? micFrames,
  }) {
    _transcriptionUpdates = transcriptionUpdates;
    _downloadProgress = downloadProgress;
    _vadEvents = vadEvents;
    _diarizationProgress = diarizationProgress;
    _eouEvents = eouEvents;
    _ttsChunks = ttsChunks;
    _micFrames = micFrames;
  }

  static final FluidEventHub instance = FluidEventHub._();

  Stream<messages.TranscriptionUpdateMessage>? _transcriptionUpdates;
  Stream<messages.DownloadProgressMessage>? _downloadProgress;
  Stream<messages.VadStreamEventMessage>? _vadEvents;
  Stream<messages.DiarizationProgressMessage>? _diarizationProgress;
  Stream<messages.EouEventMessage>? _eouEvents;
  Stream<messages.TtsChunkMessage>? _ttsChunks;
  Stream<messages.MicFrameMessage>? _micFrames;

  int _nextToken = 1;

  /// Allocates a process-unique token used to tag download-progress events.
  int allocateProgressToken() => _nextToken++;

  Stream<messages.TranscriptionUpdateMessage> get transcriptionUpdates =>
      _transcriptionUpdates ??= messages.transcriptionUpdates().asBroadcastStream();

  Stream<messages.DownloadProgressMessage> get downloadProgress =>
      _downloadProgress ??= messages.downloadProgress().asBroadcastStream();

  Stream<messages.VadStreamEventMessage> get vadEvents =>
      _vadEvents ??= messages.vadEvents().asBroadcastStream();

  Stream<messages.DiarizationProgressMessage> get diarizationProgress =>
      _diarizationProgress ??= messages.diarizationProgress().asBroadcastStream();

  Stream<messages.EouEventMessage> get eouEvents =>
      _eouEvents ??= messages.eouEvents().asBroadcastStream();

  /// Per-chunk progress of one diarizer instance's running calls.
  Stream<(int, int)> diarizationProgressFor(int instanceId) {
    return diarizationProgress
        .where((event) => event.instanceId == instanceId)
        .map((event) => (event.processedChunks, event.totalChunks));
  }

  /// Partial/utterance events for one EOU session.
  Stream<messages.EouEventMessage> eouEventsFor(int instanceId) {
    return eouEvents.where((event) => event.instanceId == instanceId);
  }

  Stream<messages.TtsChunkMessage> get ttsChunks =>
      _ttsChunks ??= messages.ttsChunks().asBroadcastStream();

  Stream<messages.MicFrameMessage> get micFrames =>
      _micFrames ??= messages.micFrames().asBroadcastStream();

  /// Synthesis frames for one TTS session.
  Stream<messages.TtsChunkMessage> ttsChunksFor(int instanceId) {
    return ttsChunks.where((chunk) => chunk.instanceId == instanceId);
  }

  /// Updates for one streaming-ASR session.
  Stream<FluidTranscriptionUpdate> updatesFor(int instanceId) {
    return transcriptionUpdates
        .where((update) => update.instanceId == instanceId)
        .map(
          (update) => FluidTranscriptionUpdate(
            text: update.text,
            isConfirmed: update.isConfirmed,
            confidence: update.confidence,
            tokenTimings: update.tokenTimings?.map(mapTokenTiming).toList(),
          ),
        );
  }

  /// Progress events for one download token. The stream closes on the
  /// `completed` phase and errors on the `failed` phase.
  Stream<FluidDownloadProgress> progressFor(int progressToken) {
    late StreamController<FluidDownloadProgress> controller;
    StreamSubscription<messages.DownloadProgressMessage>? subscription;
    controller = StreamController<FluidDownloadProgress>(
      onListen: () {
        subscription = downloadProgress
            .where((event) => event.progressToken == progressToken)
            .listen((event) {
          final progress = mapDownloadProgress(event);
          controller.add(progress);
          if (event.phase == messages.DownloadPhaseMessage.completed) {
            controller.close();
          } else if (event.phase == messages.DownloadPhaseMessage.failed) {
            controller.addError(
              FluidDownloadProgressFailure(progress.errorMessage ?? 'download failed'),
            );
            controller.close();
          }
        });
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// Ticks for one VAD stream.
  Stream<FluidVadStreamEvent> vadEventsFor(int streamId) {
    return vadEvents.where((event) => event.instanceId == streamId).map(
          (event) => FluidVadStreamEvent(
            probability: event.probability,
            isSpeechStart: event.isSpeechStart,
            isSpeechEnd: event.isSpeechEnd,
            sampleIndex: event.sampleIndex,
            time: event.timeSeconds == null ? null : durationFromSeconds(event.timeSeconds!),
          ),
        );
  }
}

class FluidDownloadProgressFailure implements Exception {
  const FluidDownloadProgressFailure(this.message);

  final String message;

  @override
  String toString() => 'FluidDownloadProgressFailure: $message';
}

FluidTokenTiming mapTokenTiming(messages.TokenTimingMessage timing) {
  return FluidTokenTiming(
    token: timing.token,
    tokenId: timing.tokenId,
    start: durationFromSeconds(timing.startSeconds),
    end: durationFromSeconds(timing.endSeconds),
    confidence: timing.confidence,
  );
}

FluidAsrResult mapAsrResult(messages.AsrResultMessage result) {
  return FluidAsrResult(
    text: result.text,
    confidence: result.confidence,
    duration: durationFromSeconds(result.durationSeconds),
    processingTime: durationFromSeconds(result.processingSeconds),
    tokenTimings: result.tokenTimings?.map(mapTokenTiming).toList(),
  );
}

FluidDownloadProgress mapDownloadProgress(messages.DownloadProgressMessage event) {
  return FluidDownloadProgress(
    fraction: event.fraction,
    phase: DownloadPhase.values[event.phase.index],
    completedFiles: event.completedFiles,
    totalFiles: event.totalFiles,
    modelName: event.modelName,
    errorMessage: event.errorMessage,
  );
}

FluidVadResult mapVadResult(messages.VadResultMessage result) {
  return FluidVadResult(
    probability: result.probability,
    isVoiceActive: result.isVoiceActive,
    processingTime: durationFromSeconds(result.processingSeconds),
  );
}
