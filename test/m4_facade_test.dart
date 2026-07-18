import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/events.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

class _FakeTtsHostApi implements messages.TtsHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  final streamedCompleter = Completer<void>();
  String? lastText;
  double? lastSpeed;
  double? lastTemperature;
  int? lastStreamToken;

  @override
  Future<int> kokoroCreate(
      messages.KokoroVariantMessage variant, String? defaultVoice, int progressToken) async {
    return 61;
  }

  @override
  Future<Uint8List> kokoroSynthesizeWav(
      int instanceId, String text, String? voice, double speed) async {
    lastText = text;
    lastSpeed = speed;
    return Uint8List.fromList([82, 73, 70, 70]); // "RIFF"
  }

  @override
  Future<messages.TtsResultMessage> kokoroSynthesizeDetailed(
      int instanceId, String text, String? voice, double speed) async {
    return messages.TtsResultMessage(
      samples: Float32List.fromList([0.1, -0.1, 0.2]).buffer.asUint8List(),
      sampleRate: 24000,
      wav: Uint8List(44),
    );
  }

  @override
  Future<int> pocketCreate(String? defaultVoice, int progressToken) async => 62;

  @override
  Future<Uint8List> pocketSynthesizeWav(
      int instanceId, String text, String? voice, double temperature) async {
    lastTemperature = temperature;
    return Uint8List(44);
  }

  @override
  Future<void> pocketSynthesizeStreaming(
      int instanceId, String text, String? voice, double temperature, int streamToken) {
    lastStreamToken = streamToken;
    return streamedCompleter.future;
  }

  @override
  Future<int> pocketCloneVoice(int instanceId, Uint8List float32Samples24k) async => 71;

  @override
  Future<Uint8List> pocketSynthesizeWithVoice(
      int instanceId, int voiceId, String text, double temperature) async {
    expect(voiceId, 71);
    return Uint8List(44);
  }

  @override
  Future<void> dispose(int instanceId) async {}
}

class _FakeAudioHostApi implements messages.AudioHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<Uint8List> resampleFile(String path) async =>
      Float32List.fromList([1, 2]).buffer.asUint8List();

  @override
  Future<Uint8List> resample(Uint8List float32Samples, double fromRate) async =>
      float32Samples;

  @override
  Future<Uint8List> encodeWav(Uint8List float32Samples, double sampleRate) async =>
      Uint8List.fromList([82, 73, 70, 70]);
}

void main() {
  test('FluidKokoroTts synthesize paths map results', () async {
    final fake = _FakeTtsHostApi();
    final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
    final tts = await FluidKokoroTts.create(hostApi: fake, events: hub);

    final wav = await tts.synthesizeWav('hi there', speed: 1.2);
    expect(fake.lastText, 'hi there');
    expect(fake.lastSpeed, 1.2);
    expect(wav, hasLength(4));

    final detailed = await tts.synthesizeDetailed('hi');
    expect(detailed.samples, hasLength(3));
    expect(detailed.sampleRate, 24000);
    expect(detailed.duration.inMicroseconds, greaterThan(0));
  });

  test('FluidPocketTts streaming demuxes by stream token and closes on sentinel', () async {
    final fake = _FakeTtsHostApi();
    final rawChunks = StreamController<messages.TtsChunkMessage>.broadcast();
    final hub = FluidEventHub.test(
      downloadProgress: const Stream.empty(),
      ttsChunks: rawChunks.stream,
    );
    final tts = await FluidPocketTts.create(hostApi: fake, events: hub);

    final received = <FluidTtsChunk>[];
    final done = tts
        .synthesizeStreaming('hello')
        .listen(received.add)
        .asFuture<void>()
        .timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    final token = fake.lastStreamToken!;
    rawChunks
      ..add(messages.TtsChunkMessage(
          streamToken: token,
          samples: Float32List(1920).buffer.asUint8List(),
          frameIndex: 0,
          chunkIndex: 0,
          chunkCount: 2,
          isLast: false))
      ..add(messages.TtsChunkMessage(
          streamToken: token + 999,
          samples: Float32List(1920).buffer.asUint8List(),
          frameIndex: 0,
          chunkIndex: 0,
          chunkCount: 1,
          isLast: false))
      ..add(messages.TtsChunkMessage(
          streamToken: token,
          samples: Uint8List(0),
          frameIndex: -1,
          chunkIndex: -1,
          chunkCount: -1,
          isLast: true));
    await done;

    expect(received, hasLength(1), reason: 'chunks for other tokens filtered out');
    expect(received.single.samples, hasLength(1920));

    final voice = await tts.cloneVoice(Float32List(48000));
    expect(await tts.synthesizeWithVoice('cloned', voice), hasLength(44));
    expect(await tts.synthesizeWav('x', temperature: 0.5), hasLength(44));
    expect(fake.lastTemperature, 0.5);
  });

  test('FluidAudioConverter round-trips helpers', () async {
    final converter = FluidAudioConverter(hostApi: _FakeAudioHostApi());
    expect(await converter.resampleFile('/tmp/a.wav'), hasLength(2));
    final resampled =
        await converter.resample(Float32List.fromList([1, 2, 3]), fromRate: 44100);
    expect(resampled, hasLength(3));
    expect(await converter.encodeWav(Float32List(10), sampleRate: 16000), hasLength(4));
  });
}
