import AVFoundation
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

  /// Wraps 16 kHz mono float32 samples in an `AVAudioPCMBuffer` for the
  /// FluidAudio streaming APIs. Buffers never cross the channel boundary
  /// (AVAudioPCMBuffer is non-Sendable); they are built here, natively.
  static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
    else {
      return nil
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let channelData = buffer.floatChannelData, !samples.isEmpty {
      samples.withUnsafeBufferPointer { source in
        channelData[0].update(from: source.baseAddress!, count: samples.count)
      }
    }
    return buffer
  }
}
