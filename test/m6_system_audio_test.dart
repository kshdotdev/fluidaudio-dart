import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/events.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

class _FakeSystemAudioHostApi implements messages.SystemAudioHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  List<int>? lastProcessIds;
  List<int>? lastAsrIds;
  bool running = false;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<List<messages.AudioProcessMessage>> listAudioProcesses() async => [
        messages.AudioProcessMessage(
            pid: 4242, bundleId: 'com.example.player', isPlayingAudio: true),
      ];

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> start(List<int> processIds, List<int> asrInstanceIds, List<int> eouInstanceIds,
      List<int> vadStreamIds, bool emitFrames) async {
    lastProcessIds = processIds;
    lastAsrIds = asrInstanceIds;
    running = true;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<bool> isRunning() async => running;
}

class _FakeStreamingAsrHostApi implements messages.StreamingAsrHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<int> create(messages.AsrVersionMessage version, messages.StreamingConfigMessage? config,
          int progressToken) async =>
      77;

  @override
  Future<void> start(int instanceId, messages.AudioSourceMessage source) async {}

  @override
  Future<void> feed(int instanceId, Uint8List float32Samples) async {}

  @override
  Future<void> configureVocabulary(int instanceId, int vocabularyId) async {}

  @override
  Future<String> finish(int instanceId) async => '';

  @override
  Future<void> reset(int instanceId) async {}

  @override
  Future<void> dispose(int instanceId) async {}
}

void main() {
  test('FluidSystemAudio passes attachments and demuxes frames', () async {
    final fake = _FakeSystemAudioHostApi();
    final rawFrames = StreamController<messages.MicFrameMessage>.broadcast();
    final hub = FluidEventHub.test(
      downloadProgress: const Stream.empty(),
      systemAudioFrames: rawFrames.stream,
    );
    final systemAudio = FluidSystemAudio(hostApi: fake, events: hub);

    expect(await systemAudio.isSupported, isTrue);
    expect(await systemAudio.requestPermission(), isTrue);

    final processes = await systemAudio.listAudioProcesses();
    expect(processes, hasLength(1));
    expect(processes.single.pid, 4242);
    expect(processes.single.bundleId, 'com.example.player');
    expect(processes.single.isPlayingAudio, isTrue);

    final session = await FluidStreamingAsr.create(
      hostApi: _FakeStreamingAsrHostApi(),
      events: hub,
    );
    await systemAudio.start(processIds: [1234], transcribers: [session]);
    expect(fake.lastProcessIds, [1234]);
    expect(fake.lastAsrIds, [77]);
    expect(await systemAudio.isRunning, isTrue);

    final frames = <FluidMicFrame>[];
    final subscription = systemAudio.frames.listen(frames.add);
    rawFrames.add(messages.MicFrameMessage(
        samples: Float32List.fromList([0.5, -0.5]).buffer.asUint8List(), rms: 0.5));
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));
    expect(frames.single.samples, hasLength(2));
    expect(frames.single.rms, closeTo(0.5, 1e-9));

    await systemAudio.stop();
    expect(await systemAudio.isRunning, isFalse);
    await subscription.cancel();
    await rawFrames.close();
  });

  test('capture health streams demux by source and map phases', () async {
    final rawHealth = StreamController<messages.CaptureHealthMessage>.broadcast();
    final hub = FluidEventHub.test(
      downloadProgress: const Stream.empty(),
      captureHealth: rawHealth.stream,
    );
    final systemAudio = FluidSystemAudio(hostApi: _FakeSystemAudioHostApi(), events: hub);
    final microphone = FluidMicrophone(
      hostApi: _FakeMicrophoneHostApi(),
      events: hub,
    );

    final systemEvents = <FluidCaptureHealth>[];
    final micEvents = <FluidCaptureHealth>[];
    final systemSubscription = systemAudio.health.listen(systemEvents.add);
    final micSubscription = microphone.health.listen(micEvents.add);

    rawHealth
      ..add(messages.CaptureHealthMessage(
          source: messages.CaptureSourceMessage.systemAudio,
          phase: messages.CaptureHealthPhaseMessage.validating,
          callbackCount: 0,
          receivingAudio: false))
      ..add(messages.CaptureHealthMessage(
          source: messages.CaptureSourceMessage.systemAudio,
          phase: messages.CaptureHealthPhaseMessage.rebuilding,
          callbackCount: 12,
          receivingAudio: false,
          detail: 'tap delivers only zero frames'))
      ..add(messages.CaptureHealthMessage(
          source: messages.CaptureSourceMessage.microphone,
          phase: messages.CaptureHealthPhaseMessage.healthy,
          callbackCount: 20,
          receivingAudio: true));
    await Future<void>.delayed(Duration.zero);

    expect(systemEvents, hasLength(2));
    expect(systemEvents[0].phase, CaptureHealthPhase.validating);
    expect(systemEvents[1].phase, CaptureHealthPhase.rebuilding);
    expect(systemEvents[1].detail, contains('zero frames'));
    expect(micEvents, hasLength(1));
    expect(micEvents.single.phase, CaptureHealthPhase.healthy);
    expect(micEvents.single.receivingAudio, isTrue);

    await systemSubscription.cancel();
    await micSubscription.cancel();
    await rawHealth.close();
  });
}

class _FakeMicrophoneHostApi implements messages.MicrophoneHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  @override
  Future<void> start(List<int> asrInstanceIds, List<int> eouInstanceIds,
      List<int> vadStreamIds, bool emitFrames) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> isRunning() async => false;
}
