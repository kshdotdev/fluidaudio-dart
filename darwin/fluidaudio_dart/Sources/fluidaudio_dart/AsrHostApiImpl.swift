import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// A loaded batch-ASR pipeline: the manager plus the version it was built for
/// (the version drives fresh decoder-state layout per transcribe call).
final class AsrInstance {
  let manager: AsrManager
  let version: AsrModelVersion

  init(manager: AsrManager, version: AsrModelVersion) {
    self.manager = manager
    self.version = version
  }
}

final class AsrHostApiImpl: AsrHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler

  init(registry: InstanceRegistry, downloadProgress: DownloadProgressHandler) {
    self.registry = registry
    self.downloadProgress = downloadProgress
  }

  private static func version(for message: AsrVersionMessage) -> AsrModelVersion {
    switch message {
    case .v2: return .v2
    case .v3: return .v3
    }
  }

  func load(
    version: AsrVersionMessage, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let modelVersion = Self.version(for: version)
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        let models = try await AsrModels.downloadAndLoad(
          version: modelVersion, progressHandler: handler)
        let config = ASRConfig(
          tdtConfig: TdtConfig(blankId: modelVersion.blankId),
          encoderHiddenSize: modelVersion.encoderHiddenSize
        )
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        let id = self.registry.add(AsrInstance(manager: manager, version: modelVersion))
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  private func transcribe(
    instanceId: Int64,
    languageCode: String?,
    completion: @escaping (Result<AsrResultMessage, Error>) -> Void,
    run: @escaping @Sendable (AsrManager, inout TdtDecoderState, Language?) async throws -> ASRResult
  ) {
    guard let instance = registry.get(instanceId, as: AsrInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "ASR")))
      return
    }
    let language = languageCode.flatMap(Language.init(rawValue:))
    Task {
      do {
        // Fresh decoder state per one-shot call: reusing it leaks LSTM state
        // across utterances and collapses output (fluidaudio-rs lesson).
        var decoderState = TdtDecoderState.make(decoderLayers: instance.version.decoderLayers)
        let result = try await run(instance.manager, &decoderState, language)
        completion(.success(TypeMapping.asrResult(result)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func transcribeSamples(
    instanceId: Int64, float32Samples: FlutterStandardTypedData, languageCode: String?,
    completion: @escaping (Result<AsrResultMessage, Error>) -> Void
  ) {
    let samples = AudioBridge.floats(from: float32Samples)
    transcribe(instanceId: instanceId, languageCode: languageCode, completion: completion) {
      manager, state, language in
      try await manager.transcribe(samples, decoderState: &state, language: language)
    }
  }

  func transcribeFile(
    instanceId: Int64, path: String, languageCode: String?,
    completion: @escaping (Result<AsrResultMessage, Error>) -> Void
  ) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      completion(
        .failure(
          PigeonError(code: "FileNotFound", message: "No file at \(path)", details: nil)))
      return
    }
    transcribe(instanceId: instanceId, languageCode: languageCode, completion: completion) {
      manager, state, language in
      try await manager.transcribe(url, decoderState: &state, language: language)
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    if let instance = registry.remove(instanceId) as? AsrInstance {
      Task {
        await instance.manager.cleanup()
        completion(.success(()))
      }
    } else {
      completion(.success(()))
    }
  }
}
