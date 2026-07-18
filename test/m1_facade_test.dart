import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/events.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

class _FakeAsrHostApi implements messages.AsrHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  messages.AsrVersionMessage? loadedVersion;
  Uint8List? lastSamples;
  String? lastLanguage;
  int disposeCalls = 0;

  @override
  Future<int> load(messages.AsrVersionMessage version, int progressToken) async {
    loadedVersion = version;
    return 7;
  }

  @override
  Future<messages.AsrResultMessage> transcribeSamples(
      int instanceId, Uint8List float32Samples, String? languageCode) async {
    expect(instanceId, 7);
    lastSamples = float32Samples;
    lastLanguage = languageCode;
    return messages.AsrResultMessage(
      text: 'hello world',
      confidence: 0.93,
      durationSeconds: 2.5,
      processingSeconds: 0.5,
      tokenTimings: [
        messages.TokenTimingMessage(
            token: 'hello', tokenId: 1, startSeconds: 0.1, endSeconds: 0.4, confidence: 0.9),
      ],
    );
  }

  @override
  Future<messages.AsrResultMessage> transcribeFile(
      int instanceId, String path, String? languageCode) async {
    return messages.AsrResultMessage(
        text: 'file', confidence: 1, durationSeconds: 1, processingSeconds: 1);
  }

  @override
  Future<void> dispose(int instanceId) async {
    disposeCalls++;
  }
}

class _FakeVadHostApi implements messages.VadHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  double? threshold;
  final fedChunks = <int>[];

  @override
  Future<int> create(double threshold, int progressToken) async {
    this.threshold = threshold;
    return 11;
  }

  @override
  Future<List<messages.VadResultMessage>> processSamples(
      int instanceId, Uint8List float32Samples) async {
    return [
      messages.VadResultMessage(probability: 0.9, isVoiceActive: true, processingSeconds: 0.01),
      messages.VadResultMessage(probability: 0.1, isVoiceActive: false, processingSeconds: 0.01),
    ];
  }

  @override
  Future<int> createStream(
      int instanceId, double? minSpeechDuration, double? minSilenceDuration) async {
    return 21;
  }

  @override
  Future<void> feedStream(int streamId, Uint8List float32Chunk) async {
    fedChunks.add(float32Chunk.length);
  }

  @override
  Future<void> resetStream(int streamId) async {}

  @override
  Future<void> disposeStream(int streamId) async {}

  @override
  Future<void> dispose(int instanceId) async {}
}

void main() {
  group('FluidAsr', () {
    test('load + transcribe maps results and passes language', () async {
      final fake = _FakeAsrHostApi();
      final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
      final asr = await FluidAsr.load(version: AsrVersion.v2, hostApi: fake, events: hub);

      expect(fake.loadedVersion, messages.AsrVersionMessage.v2);

      final samples = Float32List.fromList(List.filled(16000, 0.5));
      final result = await asr.transcribe(samples, language: 'en');

      expect(fake.lastSamples, hasLength(16000 * 4));
      expect(fake.lastLanguage, 'en');
      expect(result.text, 'hello world');
      expect(result.duration, const Duration(milliseconds: 2500));
      expect(result.rtfx, closeTo(5.0, 0.001));
      expect(result.tokenTimings, hasLength(1));
      expect(result.tokenTimings!.single.start, const Duration(milliseconds: 100));

      await asr.dispose();
      expect(fake.disposeCalls, 1);
      expect(() => asr.transcribe(samples), throwsStateError);
    });
  });

  group('FluidVad', () {
    test('create + process maps chunk results', () async {
      final fake = _FakeVadHostApi();
      final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
      final vad = await FluidVad.create(threshold: 0.7, hostApi: fake, events: hub);

      expect(fake.threshold, 0.7);
      final results = await vad.process(Float32List(8192));
      expect(results, hasLength(2));
      expect(results.first.isVoiceActive, isTrue);
      expect(results.last.probability, closeTo(0.1, 1e-9));
    });

    test('stream feeds chunks and demuxes events by stream id', () async {
      final fake = _FakeVadHostApi();
      final rawEvents = StreamController<messages.VadStreamEventMessage>.broadcast();
      final hub = FluidEventHub.test(
        downloadProgress: const Stream.empty(),
        vadEvents: rawEvents.stream,
      );
      final vad = await FluidVad.create(hostApi: fake, events: hub);
      final stream = await vad.stream();

      final received = <FluidVadStreamEvent>[];
      final subscription = stream.events.listen(received.add);

      await stream.feed(Float32List(4096));
      expect(fake.fedChunks, [4096 * 4]);

      rawEvents
        ..add(messages.VadStreamEventMessage(
            instanceId: 21, probability: 0.8, isSpeechStart: true, isSpeechEnd: false,
            sampleIndex: 0, timeSeconds: 0.0))
        ..add(messages.VadStreamEventMessage(
            instanceId: 99, probability: 0.5, isSpeechStart: false, isSpeechEnd: false));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1), reason: 'event for stream 99 must be filtered out');
      expect(received.single.isSpeechStart, isTrue);
      await subscription.cancel();
    });
  });

  group('FluidEventHub.progressFor', () {
    test('closes on completed and filters by token', () async {
      final raw = StreamController<messages.DownloadProgressMessage>.broadcast();
      final hub = FluidEventHub.test(downloadProgress: raw.stream);

      final events = <FluidDownloadProgress>[];
      final done = hub
          .progressFor(5)
          .listen(events.add)
          .asFuture<void>()
          .timeout(const Duration(seconds: 1));

      raw
        ..add(messages.DownloadProgressMessage(
            progressToken: 5, fraction: 0.5, phase: messages.DownloadPhaseMessage.downloading,
            completedFiles: 1, totalFiles: 2))
        ..add(messages.DownloadProgressMessage(
            progressToken: 6, fraction: 0.9, phase: messages.DownloadPhaseMessage.downloading))
        ..add(messages.DownloadProgressMessage(
            progressToken: 5, fraction: 1.0, phase: messages.DownloadPhaseMessage.completed));

      await done;
      expect(events, hasLength(2));
      expect(events.first.phase, DownloadPhase.downloading);
      expect(events.first.completedFiles, 1);
      expect(events.last.phase, DownloadPhase.completed);
      await raw.close();
    });
  });
}
