import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Decodes a 16-bit PCM RIFF/WAVE payload to float32 samples in [-1, 1].
///
/// Scans chunks rather than assuming a 44-byte header (some encoders insert
/// LIST/fact chunks before `data`).
Float32List decodeWav16(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 12 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      final sampleCount = size ~/ 2;
      final samples = Float32List(sampleCount);
      for (var i = 0; i < sampleCount; i++) {
        samples[i] = data.getInt16(offset + 8 + i * 2, Endian.little) / 32768.0;
      }
      return samples;
    }
    offset += 8 + size + (size & 1);
  }
  throw const FormatException('no data chunk found');
}

/// Loads a bundled wav asset as 16 kHz float32 samples.
Future<Float32List> loadWavAsset(String assetPath) async {
  final bytes = await rootBundle.load(assetPath);
  return decodeWav16(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
}

/// Copies a bundled wav asset to a temp file and returns its path
/// (for file-based APIs, so audio never crosses the channel).
Future<String> materializeWavAsset(String assetPath) async {
  final bytes = await rootBundle.load(assetPath);
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}/${assetPath.split('/').last}');
  await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  return file.path;
}
