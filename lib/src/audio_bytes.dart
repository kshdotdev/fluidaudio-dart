import 'dart:typed_data';

/// Audio crosses the platform channel as little-endian float32 bytes
/// (pigeon has no Float32List type). These helpers convert without copying
/// sample data when alignment allows.

/// Views [samples] as bytes without copying elements.
Uint8List floatsToBytes(Float32List samples) {
  return samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes);
}

/// Views [bytes] as float32 samples without copying elements when aligned.
Float32List bytesToFloats(Uint8List bytes) {
  if (bytes.offsetInBytes % Float32List.bytesPerElement == 0) {
    return bytes.buffer.asFloat32List(
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ Float32List.bytesPerElement,
    );
  }
  final aligned = Uint8List.fromList(bytes);
  return aligned.buffer.asFloat32List(0, aligned.lengthInBytes ~/ Float32List.bytesPerElement);
}
