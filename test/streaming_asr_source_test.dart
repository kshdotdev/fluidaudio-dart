import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/events.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

class _FakeStreamingAsrHostApi implements messages.StreamingAsrHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  final List<messages.AudioSourceMessage> startedSources = [];

  @override
  Future<int> create(
    messages.AsrVersionMessage version,
    messages.StreamingConfigMessage? config,
    int progressToken,
  ) async =>
      17;

  @override
  Future<void> start(
    int instanceId,
    messages.AudioSourceMessage source,
  ) async {
    expect(instanceId, 17);
    startedSources.add(source);
  }

  @override
  Future<void> configureVocabulary(int instanceId, int vocabularyId) async {}

  @override
  Future<void> feed(int instanceId, Uint8List float32Samples) async {}

  @override
  Future<String> finish(int instanceId) async => '';

  @override
  Future<void> reset(int instanceId) async {}

  @override
  Future<void> dispose(int instanceId) async {}
}

void main() {
  test('start forwards microphone and system source tags to the host', () async {
    final fake = _FakeStreamingAsrHostApi();
    final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
    final session = await FluidStreamingAsr.create(
      hostApi: fake,
      events: hub,
    );

    await session.start();
    await session.start(source: FluidAudioSource.system);

    expect(fake.startedSources, [
      messages.AudioSourceMessage.microphone,
      messages.AudioSourceMessage.system,
    ]);
    await session.dispose();
  });
}
