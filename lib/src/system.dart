import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'messages.g.dart' as messages;

/// System information reported by the native FluidAudio runtime.
class FluidSystemInfo {
  const FluidSystemInfo({
    required this.summary,
    required this.isAppleSilicon,
    required this.isIntelMac,
    required this.qwen3Supported,
  });

  /// Human-readable summary (platform, chip, memory).
  final String summary;

  final bool isAppleSilicon;

  /// True on Intel Macs, where FluidAudio's ASR models cannot run.
  final bool isIntelMac;

  /// Whether Qwen3 models can run on this OS (macOS 15+ / iOS 18+).
  final bool qwen3Supported;
}

/// Diagnostic event from the native side (validates the event-channel bridge).
class FluidDebugEvent {
  const FluidDebugEvent({required this.sequence, required this.message, this.payload});

  final int sequence;
  final String message;
  final Float32List? payload;
}

/// Entry point for system-level queries and channel diagnostics.
class FluidAudioSystem {
  FluidAudioSystem({@visibleForTesting messages.SystemHostApi? hostApi})
      : _hostApi = hostApi ?? messages.SystemHostApi();

  final messages.SystemHostApi _hostApi;

  Future<FluidSystemInfo> info() async {
    final info = await _hostApi.systemInfo();
    return FluidSystemInfo(
      summary: info.summary,
      isAppleSilicon: info.isAppleSilicon,
      isIntelMac: info.isIntelMac,
      qwen3Supported: info.qwen3Supported,
    );
  }

  /// Round-trips [samples] through the native side unchanged.
  ///
  /// Diagnostic for the audio-buffer convention (float32 bytes over the
  /// channel); also exercises the native `AudioBridge` conversions.
  Future<Float32List> echoFloats(Float32List samples) async {
    final bytes = await _hostApi.echoFloats(floatsToBytes(samples));
    return bytesToFloats(bytes);
  }

  /// Events emitted by [debugEmitEvents]; validates native → Dart streaming.
  Stream<FluidDebugEvent> debugEvents() {
    return messages.debugEvents().map(
          (event) => FluidDebugEvent(
            sequence: event.sequence,
            message: event.message,
            payload: event.payload == null ? null : bytesToFloats(event.payload!),
          ),
        );
  }

  /// Asks the native side to emit [count] events on [debugEvents].
  Future<void> debugEmitEvents(int count) => _hostApi.debugEmitEvents(count);
}

/// Views [samples] as little-endian float32 bytes without copying elements.
@visibleForTesting
Uint8List floatsToBytes(Float32List samples) {
  return samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes);
}

/// Views [bytes] as float32 samples without copying elements.
@visibleForTesting
Float32List bytesToFloats(Uint8List bytes) {
  if (bytes.offsetInBytes % Float32List.bytesPerElement == 0) {
    return bytes.buffer.asFloat32List(
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ Float32List.bytesPerElement,
    );
  }
  // Unaligned view is not allowed; fall back to a copy.
  final aligned = Uint8List.fromList(bytes);
  return aligned.buffer.asFloat32List(0, aligned.lengthInBytes ~/ Float32List.bytesPerElement);
}
