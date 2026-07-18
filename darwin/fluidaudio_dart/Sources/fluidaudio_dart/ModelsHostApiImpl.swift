import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class ModelsHostApiImpl: ModelsHostApi {
  private let downloadProgress: DownloadProgressHandler

  init(downloadProgress: DownloadProgressHandler) {
    self.downloadProgress = downloadProgress
  }

  private func repo(for kind: ModelKindMessage) -> Repo {
    switch kind {
    case .vad: return .vad
    case .parakeetV2: return .parakeetV2
    case .parakeetV3: return .parakeetV3
    }
  }

  private func asrVersion(for kind: ModelKindMessage) -> AsrModelVersion? {
    switch kind {
    case .parakeetV2: return .v2
    case .parakeetV3: return .v3
    case .vad: return nil
    }
  }

  func isDownloaded(kind: ModelKindMessage, completion: @escaping (Result<Bool, Error>) -> Void) {
    if let version = asrVersion(for: kind) {
      let directory = AsrModels.defaultCacheDirectory(for: version)
      completion(.success(AsrModels.modelsExist(at: directory, version: version)))
      return
    }
    // VAD: the repo folder existing and being non-empty is the best public check.
    let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: repo(for: kind))
    let contents =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    completion(.success(!contents.isEmpty))
  }

  func download(
    kind: ModelKindMessage, progressToken: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        if let version = self.asrVersion(for: kind) {
          _ = try await AsrModels.download(version: version, progressHandler: handler)
        } else {
          // VAD models download inside the manager's async init.
          _ = try await VadManager(config: .default, progressHandler: handler)
        }
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(()))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func remove(kind: ModelKindMessage, completion: @escaping (Result<Void, Error>) -> Void) {
    let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: repo(for: kind))
    do {
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
      completion(.success(()))
    } catch {
      completion(.failure(ErrorMapping.map(error)))
    }
  }

  func cacheDirectory(
    kind: ModelKindMessage, completion: @escaping (Result<String, Error>) -> Void
  ) {
    completion(
      .success(MLModelConfigurationUtils.defaultModelsDirectory(for: repo(for: kind)).path))
  }

  func setOfflineMode(enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
    ModelHub.offlineMode = enabled
    completion(.success(()))
  }
}
