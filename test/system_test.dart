import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/src/audio_bytes.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;
import 'package:fluidaudio_dart/src/system.dart';

class _FakeSystemHostApi implements messages.SystemHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  Uint8List? lastEchoedBytes;
  int? lastEmitCount;

  @override
  Future<messages.SystemInfoMessage> systemInfo() async {
    return messages.SystemInfoMessage(
      summary: 'Apple M4 Pro · 48 GB',
      isAppleSilicon: true,
      isIntelMac: false,
      qwen3Supported: true,
    );
  }

  @override
  Future<Uint8List> echoFloats(Uint8List samples) async {
    lastEchoedBytes = samples;
    return samples;
  }

  @override
  Future<void> debugEmitEvents(int count) async {
    lastEmitCount = count;
  }
}

void main() {
  group('FluidAudioSystem', () {
    test('info maps the pigeon message to the domain type', () async {
      final system = FluidAudioSystem(hostApi: _FakeSystemHostApi());
      final info = await system.info();
      expect(info.summary, 'Apple M4 Pro · 48 GB');
      expect(info.isAppleSilicon, isTrue);
      expect(info.isIntelMac, isFalse);
      expect(info.qwen3Supported, isTrue);
    });

    test('echoFloats round-trips samples through the byte convention', () async {
      final fake = _FakeSystemHostApi();
      final system = FluidAudioSystem(hostApi: fake);
      final samples = Float32List.fromList([0.0, -1.5, 3.25, 16000.0]);

      final result = await system.echoFloats(samples);

      expect(result, samples);
      expect(fake.lastEchoedBytes, hasLength(samples.length * 4));
    });

    test('debugEmitEvents forwards the count', () async {
      final fake = _FakeSystemHostApi();
      final system = FluidAudioSystem(hostApi: fake);
      await system.debugEmitEvents(3);
      expect(fake.lastEmitCount, 3);
    });
  });

  group('byte conversion helpers', () {
    test('floatsToBytes/bytesToFloats are lossless and copy-free when aligned', () {
      final samples = Float32List.fromList(List.generate(1000, (i) => i * 0.5));
      final bytes = floatsToBytes(samples);
      final restored = bytesToFloats(bytes);
      expect(restored, samples);
      // Copy-free proof: writes through the restored view reach the original.
      restored[0] = 42.0;
      expect(samples[0], 42.0);
    });

    test('bytesToFloats copies when the view is unaligned', () {
      final backing = Uint8List(9);
      final bytes = Uint8List.view(backing.buffer, 1, 8);
      final restored = bytesToFloats(bytes);
      expect(restored, hasLength(2));
    });
  });
}
