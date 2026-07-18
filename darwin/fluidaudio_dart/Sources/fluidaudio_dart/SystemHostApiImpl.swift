import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class SystemHostApiImpl: SystemHostApi {
  private let debugEvents: DebugEventsHandler

  init(debugEvents: DebugEventsHandler) {
    self.debugEvents = debugEvents
  }

  func systemInfo(completion: @escaping (Result<SystemInfoMessage, Error>) -> Void) {
    let qwen3Supported: Bool
    if #available(macOS 15, iOS 18, *) {
      qwen3Supported = true
    } else {
      qwen3Supported = false
    }
    completion(
      .success(
        SystemInfoMessage(
          summary: SystemInfo.summary(),
          isAppleSilicon: SystemInfo.isAppleSilicon,
          isIntelMac: SystemInfo.isIntelMac,
          qwen3Supported: qwen3Supported
        )))
  }

  func echoFloats(
    samples: FlutterStandardTypedData,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    let floats = AudioBridge.floats(from: samples)
    completion(.success(AudioBridge.typedData(from: floats)))
  }

  func debugEmitEvents(count: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    for sequence in 0..<count {
      let payload = AudioBridge.typedData(from: [Float(sequence), Float(sequence) + 0.5])
      debugEvents.emit(
        DebugEventMessage(sequence: sequence, message: "event-\(sequence)", payload: payload))
    }
    completion(.success(()))
  }
}
