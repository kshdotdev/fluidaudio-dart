import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/events.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

Uint8List _floatBytes(List<double> values) =>
    Float32List.fromList(values).buffer.asUint8List();

class _FakeDiarizerHostApi implements messages.DiarizerHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  double? threshold;
  int? numSpeakers;
  int? lastOperationId;
  final operationIds = <int>[];
  final cancelOperationIds = <int>[];
  final pending = <int, Completer<messages.DiarizationResultMessage>>{};
  bool holdDiarizations = false;
  int disposeCalls = 0;

  @override
  Future<int> create(double clusteringThreshold, int? numSpeakers, int? minSpeakers,
      int? maxSpeakers, bool exposeChunkEmbeddings, int progressToken) async {
    threshold = clusteringThreshold;
    this.numSpeakers = numSpeakers;
    return 31;
  }

  @override
  Future<messages.DiarizationResultMessage> diarizeSamples(
    int instanceId,
    int operationId,
    Uint8List float32Samples,
  ) async {
    expect(instanceId, 31);
    lastOperationId = operationId;
    operationIds.add(operationId);
    if (holdDiarizations) {
      final completer = Completer<messages.DiarizationResultMessage>();
      pending[operationId] = completer;
      return completer.future;
    }
    return messages.DiarizationResultMessage(
      segments: [
        messages.DiarizationSegmentMessage(
          speakerId: 'S1',
          startSeconds: 0.5,
          endSeconds: 2.5,
          qualityScore: 0.9,
          embedding: _floatBytes([0.1, 0.2, 0.3]),
        ),
        messages.DiarizationSegmentMessage(
          speakerId: 'S2',
          startSeconds: 3.0,
          endSeconds: 5.0,
          qualityScore: 0.8,
          embedding: _floatBytes([0.4, 0.5, 0.6]),
        ),
      ],
      speakerDatabase: [
        messages.SpeakerEmbeddingMessage(speakerId: 'S1', embedding: _floatBytes([0.1])),
      ],
      timings: messages.DiarizationTimingsMessage(
        segmentationSeconds: 0.1,
        embeddingExtractionSeconds: 0.2,
        speakerClusteringSeconds: 0.3,
        postProcessingSeconds: 0.4,
        totalInferenceSeconds: 1.0,
        totalProcessingSeconds: 1.1,
      ),
    );
  }

  @override
  Future<messages.DiarizationResultMessage> diarizeFile(
    int instanceId,
    int operationId,
    String path,
  ) async {
    expect(instanceId, 31);
    lastOperationId = operationId;
    operationIds.add(operationId);
    if (holdDiarizations) {
      final completer = Completer<messages.DiarizationResultMessage>();
      pending[operationId] = completer;
      return completer.future;
    }
    return messages.DiarizationResultMessage(segments: []);
  }

  @override
  Future<void> cancel(int instanceId, int operationId) async {
    expect(instanceId, 31);
    cancelOperationIds.add(operationId);
    _cancelPending(operationId);
  }

  @override
  Future<void> dispose(int instanceId) async {
    expect(instanceId, 31);
    disposeCalls++;
    for (final operationId in pending.keys.toList()) {
      _cancelPending(operationId);
    }
  }

  void _cancelPending(int operationId) {
    final completer = pending.remove(operationId);
    if (completer == null || completer.isCompleted) return;
    completer.completeError(
      PlatformException(
        code: 'OperationCancelled',
        message: 'Native operation $operationId was cancelled.',
      ),
    );
  }
}

class _FakeEouHostApi implements messages.EouHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  messages.EouChunkSizeMessage? chunkSize;
  int? debounceMs;

  @override
  Future<int> create(
      messages.EouChunkSizeMessage chunkSize, int eouDebounceMs, int progressToken) async {
    this.chunkSize = chunkSize;
    debounceMs = eouDebounceMs;
    return 41;
  }

  @override
  Future<void> feed(int instanceId, Uint8List float32Samples) async {}

  @override
  Future<String> finish(int instanceId) async => 'final text';

  @override
  Future<void> reset(int instanceId) async {}

  @override
  Future<void> dispose(int instanceId) async {}
}

void main() {
  test('FluidDiarizer maps segments, embeddings and timings', () async {
    final fake = _FakeDiarizerHostApi();
    final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
    final diarizer = await FluidDiarizer.create(
      clusteringThreshold: 0.7,
      numSpeakers: 2,
      hostApi: fake,
      events: hub,
    );

    expect(fake.threshold, 0.7);
    expect(fake.numSpeakers, 2);

    final result = await diarizer.diarize(Float32List(16000));
    expect(fake.lastOperationId, 1);
    expect(result.segments, hasLength(2));
    expect(result.speakerIds, {'S1', 'S2'});
    expect(result.segments.first.start, const Duration(milliseconds: 500));
    expect(result.segments.first.embedding, hasLength(3));
    expect(result.segments.first.embedding[1], closeTo(0.2, 1e-6));
    expect(result.speakerDatabase, hasLength(1));
    expect(result.timings!.totalProcessing, const Duration(milliseconds: 1100));
    await diarizer.dispose();
  });

  test('FluidDiarizer cancellation forwards identity exactly once', () async {
    final fake = _FakeDiarizerHostApi()..holdDiarizations = true;
    final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
    final diarizer = await FluidDiarizer.create(hostApi: fake, events: hub);

    final operation = diarizer.startDiarization(Float32List(16000));
    expect(operation.operationId, 1);
    expect(operation.isCancellationRequested, isFalse);
    final result = expectLater(
      operation.result,
      throwsA(isA<FluidOperationCancelledException>()),
    );

    final firstCancellation = operation.cancel();
    final secondCancellation = operation.cancel();

    expect(identical(firstCancellation, secondCancellation), isTrue);
    expect(operation.isCancellationRequested, isTrue);
    await firstCancellation;
    await result;
    expect(fake.cancelOperationIds, [1]);
    await diarizer.dispose();
  });

  test('FluidDiarizer operation ids span sample and file calls', () async {
    final fake = _FakeDiarizerHostApi();
    final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
    final diarizer = await FluidDiarizer.create(hostApi: fake, events: hub);

    final samples = diarizer.startDiarization(Float32List(16000));
    final file = diarizer.startFileDiarization('/tmp/example.wav');
    await Future.wait([samples.result, file.result]);

    expect(samples.operationId, 1);
    expect(file.operationId, 2);
    expect(fake.operationIds, [1, 2]);
    await diarizer.dispose();
  });

  test('FluidDiarizer dispose cancels work and shares completion', () async {
    final fake = _FakeDiarizerHostApi()..holdDiarizations = true;
    final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
    final diarizer = await FluidDiarizer.create(hostApi: fake, events: hub);
    final operation = diarizer.startDiarization(Float32List(16000));
    final result = expectLater(
      operation.result,
      throwsA(isA<FluidOperationCancelledException>()),
    );

    final firstDispose = diarizer.dispose();
    final secondDispose = diarizer.dispose();

    expect(identical(firstDispose, secondDispose), isTrue);
    await firstDispose;
    await result;
    expect(fake.disposeCalls, 1);
    expect(
      () => diarizer.startDiarization(Float32List(16000)),
      throwsStateError,
    );
  });

  test('FluidEou demuxes partials and utterances by instance id', () async {
    final fake = _FakeEouHostApi();
    final rawEvents = StreamController<messages.EouEventMessage>.broadcast();
    final hub = FluidEventHub.test(
      downloadProgress: const Stream.empty(),
      eouEvents: rawEvents.stream,
    );
    final eou = await FluidEou.create(
      chunkSize: EouChunkSize.ms160,
      eouDebounceMs: 900,
      hostApi: fake,
      events: hub,
    );

    expect(fake.chunkSize, messages.EouChunkSizeMessage.ms160);
    expect(fake.debounceMs, 900);

    final partials = <String>[];
    final utterances = <String>[];
    final partialSubscription = eou.partials.listen(partials.add);
    final utteranceSubscription = eou.utterances.listen(utterances.add);

    rawEvents
      ..add(messages.EouEventMessage(instanceId: 41, isUtteranceEnd: false, text: 'hel'))
      ..add(messages.EouEventMessage(instanceId: 41, isUtteranceEnd: true, text: 'hello'))
      ..add(messages.EouEventMessage(instanceId: 99, isUtteranceEnd: true, text: 'other'));
    await Future<void>.delayed(Duration.zero);

    expect(partials, ['hel']);
    expect(utterances, ['hello']);
    expect(await eou.finish(), 'final text');

    await partialSubscription.cancel();
    await utteranceSubscription.cancel();
    await rawEvents.close();
  });
}
