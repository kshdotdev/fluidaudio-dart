// Pigeon schema for fluidaudio_dart.
//
// Regenerate with:
//   dart run pigeon --input pigeons/fluidaudio.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    swiftOut: 'darwin/fluidaudio_dart/Sources/fluidaudio_dart/Messages.g.swift',
    dartPackageName: 'fluidaudio_dart',
  ),
)
/// System information reported by the native FluidAudio runtime.
class SystemInfoMessage {
  SystemInfoMessage({
    required this.summary,
    required this.isAppleSilicon,
    required this.isIntelMac,
    required this.qwen3Supported,
  });

  /// Human-readable summary from FluidAudio's `SystemInfo.summary()`.
  String summary;

  bool isAppleSilicon;
  bool isIntelMac;

  /// Whether Qwen3 models can run on this OS (macOS 15+ / iOS 18+).
  bool qwen3Supported;
}

/// Diagnostic event used to validate the native → Dart event-channel bridge.
class DebugEventMessage {
  DebugEventMessage({required this.sequence, required this.message, this.payload});

  int sequence;
  String message;

  /// Optional typed-data payload (validates typed data inside event DTOs).
  ///
  /// Convention: little-endian float32 bytes. Pigeon has no Float32List type,
  /// so audio buffers cross the channel as Uint8List byte-views
  /// (`Float32List.view(bytes.buffer)` on the Dart side — no element copy).
  Uint8List? payload;
}

@HostApi()
abstract class SystemHostApi {
  @async
  SystemInfoMessage systemInfo();

  /// Round-trips a float32-bytes buffer across the channel (typed-data probe).
  @async
  Uint8List echoFloats(Uint8List samples);

  /// Emits [count] events on the `debugEvents` stream (event-channel probe).
  @async
  void debugEmitEvents(int count);
}

@EventChannelApi()
abstract class FluidAudioEventChannelApi {
  DebugEventMessage debugEvents();
}
