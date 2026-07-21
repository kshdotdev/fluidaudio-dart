import FluidAudio
import Foundation

/// Shared cache-path logic for the end-of-utterance (EOU) streaming models.
///
/// The plugin keeps the EOU models under the standard FluidAudio models root
/// (`.../FluidAudio/Models/<repo.folderName>`), the same layout every other
/// model kind uses. `StreamingEouAsrManager.loadModels(to: nil)` would instead
/// resolve a private default root that already ends in
/// `parakeet-eou-streaming` and then append the repo folder again, producing a
/// doubled `parakeet-eou-streaming/parakeet-eou-streaming/<chunk>` layout — so
/// every load/download in this plugin passes the explicit root, and caches
/// written through the doubled layout (fluidaudio_dart 0.1.0) are migrated in
/// place to keep the ~450 MB download.
enum EouModelCache {
  /// The models root shared by every kind: `.../FluidAudio/Models`.
  static var modelsRoot: URL { MLModelConfigurationUtils.defaultModelsDirectory() }

  /// First segment of every EOU repo's `folderName`, and the name of the
  /// legacy doubled parent directory.
  private static let eouFolder = "parakeet-eou-streaming"

  /// `.../Models/parakeet-eou-streaming` — parent of every chunk variant.
  static var eouDirectory: URL {
    modelsRoot.appendingPathComponent(eouFolder, isDirectory: true)
  }

  static func repo(for chunkSize: EouChunkSizeMessage) -> Repo {
    switch chunkSize {
    case .ms160: return .parakeetEou160
    case .ms320: return .parakeetEou320
    case .ms1280: return .parakeetEou1280
    }
  }

  static func directory(for repo: Repo) -> URL {
    modelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
  }

  static func isDownloaded(_ repo: Repo) -> Bool {
    migrateLegacyCache()
    let directory = directory(for: repo)
    return ModelNames.ParakeetEOU.requiredModels.allSatisfy { model in
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(model).path)
    }
  }

  /// Moves chunk variants out of the legacy doubled layout into the standard
  /// one. Best-effort: on any failure the variant is left in place and a fresh
  /// download proceeds normally (already-present files are skipped per file).
  static func migrateLegacyCache() {
    let fileManager = FileManager.default
    let legacyParent = eouDirectory.appendingPathComponent(eouFolder, isDirectory: true)
    guard fileManager.fileExists(atPath: legacyParent.path) else { return }
    let variants = (try? fileManager.contentsOfDirectory(atPath: legacyParent.path)) ?? []
    for variant in variants {
      let source = legacyParent.appendingPathComponent(variant, isDirectory: true)
      let target = eouDirectory.appendingPathComponent(variant, isDirectory: true)
      guard !fileManager.fileExists(atPath: target.path) else { continue }
      try? fileManager.moveItem(at: source, to: target)
    }
    if ((try? fileManager.contentsOfDirectory(atPath: legacyParent.path)) ?? []).isEmpty {
      try? fileManager.removeItem(at: legacyParent)
    }
  }
}
