import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;

/// Audio conversion utilities backed by FluidAudio's native `AudioConverter`.
class FluidAudioConverter {
  FluidAudioConverter({@visibleForTesting messages.AudioHostApi? hostApi})
      : _hostApi = hostApi ?? messages.AudioHostApi();

  final messages.AudioHostApi _hostApi;

  /// Decodes any audio file (wav/m4a/mp3/...) to 16 kHz mono float32 samples.
  Future<Float32List> resampleFile(String path) async {
    final bytes = await wrapPlatformErrors(() => _hostApi.resampleFile(path));
    return bytesToFloats(bytes);
  }

  /// Resamples [samples] from [fromRate] to 16 kHz mono.
  Future<Float32List> resample(Float32List samples, {required double fromRate}) async {
    final bytes = await wrapPlatformErrors(
        () => _hostApi.resample(floatsToBytes(samples), fromRate));
    return bytesToFloats(bytes);
  }

  /// Encodes float32 [samples] as a 16-bit PCM WAV file.
  Future<Uint8List> encodeWav(Float32List samples, {required double sampleRate}) {
    return wrapPlatformErrors(
        () => _hostApi.encodeWav(floatsToBytes(samples), sampleRate));
  }
}
