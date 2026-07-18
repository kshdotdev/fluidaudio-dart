import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Conversions between the channel's byte-buffer convention and Swift audio types.
///
/// Audio crosses the platform channel as little-endian float32 bytes
/// (`Uint8List` on the Dart side — pigeon has no Float32List type).
enum AudioBridge {
  static func floats(from data: FlutterStandardTypedData) -> [Float] {
    let bytes = data.data
    let count = bytes.count / MemoryLayout<Float>.size
    var floats = [Float](repeating: 0, count: count)
    _ = floats.withUnsafeMutableBytes { destination in
      bytes.copyBytes(to: destination, count: count * MemoryLayout<Float>.size)
    }
    return floats
  }

  static func typedData(from floats: [Float]) -> FlutterStandardTypedData {
    let data = floats.withUnsafeBytes { Data($0) }
    return FlutterStandardTypedData(bytes: data)
  }
}
