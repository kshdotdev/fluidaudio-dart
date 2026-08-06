import FluidAudio
import Foundation

/// Process-global model root resolution shared by every host API impl.
///
/// FluidAudio resolves ASR/VAD/diarizer/EOU/CTC models as
/// `<modelsRoot>/<repo.folderName>/<files>`; TTS assets live under a separate
/// tree rooted at `TtsCacheDirectory`. A host app that manages model artifacts
/// itself points either root at its own directory before creating any model
/// instance.
///
/// Mutation is forbidden once any model instance exists: FluidAudio caches
/// compiled `MLModel`s per process, so a late swap would silently keep serving
/// models from the old root while reporting the new one.
enum ModelPaths {
  private static let lock = NSLock()
  private static var modelsRootOverride: URL?
  private static var ttsRootOverride: URL?
  private static var instanceCreated = false

  /// The models root shared by ASR, VAD, diarizer, EOU, and CTC kinds.
  static var modelsRoot: URL {
    lock.lock()
    defer { lock.unlock() }
    return modelsRootOverride ?? MLModelConfigurationUtils.defaultModelsDirectory()
  }

  /// `<modelsRoot>/<repo.folderName>` — the directory holding [repo]'s files.
  static func repoDirectory(_ repo: Repo) -> URL {
    modelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
  }

  /// The repo directory for an ASR model version. `AsrModelVersion.repo` is
  /// internal upstream, so the mapping is mirrored here.
  static func asrRepoDirectory(_ version: AsrModelVersion) -> URL {
    switch version {
    case .v2: return repoDirectory(.parakeetV2)
    case .v3: return repoDirectory(.parakeetV3)
    case .tdtCtc110m: return repoDirectory(.parakeetTdtCtc110m)
    case .tdtJa: return repoDirectory(.parakeetJa)
    }
  }

  /// The TTS assets root (`~/.cache/fluidaudio` by default on macOS).
  ///
  /// Upstream limitation: the English Kokoro G2P pipeline (`G2PModel`) reads
  /// from `TtsCacheDirectory` directly and cannot be redirected; every other
  /// TTS asset honors the override.
  static func ttsRoot() throws -> URL {
    lock.lock()
    let override = ttsRootOverride
    lock.unlock()
    if let override { return override }
    return try TtsCacheDirectory.ensure()
  }

  /// The roots currently in effect, with defaults resolved to real paths.
  static func currentRoots() throws -> (models: URL, tts: URL) {
    (models: modelsRoot, tts: try ttsRoot())
  }

  /// Replaces both roots. `nil` fields restore FluidAudio's own caches.
  ///
  /// Rejects paths that do not name an existing directory, and rejects any
  /// mutation after the first model instance was created in this process.
  static func setRoots(models: URL?, tts: URL?) throws {
    lock.lock()
    defer { lock.unlock() }
    if instanceCreated {
      throw PigeonError(
        code: "ModelRootsLocked",
        message:
          "Model roots cannot change after a model instance was created: "
          + "compiled models are cached per process. Set roots at startup, "
          + "before loading any recognizer, VAD, diarizer, EOU, or TTS model.",
        details: nil
      )
    }
    for url in [models, tts].compactMap({ $0 }) {
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(
        atPath: url.path, isDirectory: &isDirectory)
      guard exists, isDirectory.boolValue else {
        throw PigeonError(
          code: "ModelRootsInvalid",
          message: "Model root is not an existing directory: \(url.path)",
          details: nil
        )
      }
    }
    modelsRootOverride = models
    ttsRootOverride = tts
  }

  /// Marks the process as owning at least one live model instance, freezing
  /// the roots. Called by every host API create/load path on success.
  static func registerInstanceCreated() {
    lock.lock()
    defer { lock.unlock() }
    instanceCreated = true
  }

  /// Test hook: clears overrides and the instance-created latch.
  static func resetForTesting() {
    lock.lock()
    defer { lock.unlock() }
    modelsRootOverride = nil
    ttsRootOverride = nil
    instanceCreated = false
  }
}
