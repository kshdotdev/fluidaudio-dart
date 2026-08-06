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
    // ModelKind.eou manages the ms320 chunk variant — FluidEou.create's default.
    case .eou: return .parakeetEou320
    case .diarizer: return .diarizer
    case .ctc110m: return .parakeetCtc110m
    // ModelKind.kokoro manages the ANE English bundle — FluidKokoroTts's default.
    case .kokoro: return .kokoroAne
    case .pocketTts: return .pocketTts
    }
  }

  private func asrVersion(for kind: ModelKindMessage) -> AsrModelVersion? {
    switch kind {
    case .parakeetV2: return .v2
    case .parakeetV3: return .v3
    case .vad, .eou, .diarizer, .ctc110m, .kokoro, .pocketTts: return nil
    }
  }

  // MARK: - Cache layout

  /// The TTS backends cache under FluidAudio's shared TTS root
  /// (`~/.cache/fluidaudio` on macOS, Application Support on iOS) — a
  /// different tree from the ASR/diarizer models root. Honors the host
  /// override set through `setModelRoots`.
  private func ttsModelsRoot(_ subdirectory: String) throws -> URL {
    try ModelPaths.ttsRoot().appendingPathComponent(subdirectory, isDirectory: true)
  }

  /// `<tts>/Models/kokoro-82m-coreml/ANE` — the English ANE bundle.
  private func kokoroDirectory() throws -> URL {
    try ttsModelsRoot(KokoroAneResourceDownloader.modelsSubdirectory)
      .appendingPathComponent(Repo.kokoroAne.folderName, isDirectory: true)
  }

  /// `<tts>/Models/kokoro` — the shared G2P (text → IPA) assets every Kokoro
  /// variant loads; downloaded separately from the voice bundle upstream.
  ///
  /// Deliberately resolved at the DEFAULT TTS cache, never the host override:
  /// upstream `KokoroAneManager.initialize()`/`G2PModel` read G2P assets from
  /// `TtsCacheDirectory` unconditionally (no directory hook), so staging or
  /// probing them anywhere else would put bytes where nothing ever reads.
  private func kokoroG2pDirectory() throws -> URL {
    try TtsCacheDirectory.ensure()
      .appendingPathComponent(
        KokoroAneResourceDownloader.modelsSubdirectory, isDirectory: true
      )
      .appendingPathComponent(Repo.kokoro.folderName, isDirectory: true)
  }

  /// `<tts>/Models/pocket-tts` — the repo root shared by every language pack.
  private func pocketTtsRepoDirectory() throws -> URL {
    try ttsModelsRoot(PocketTtsConstants.defaultModelsSubdirectory)
      .appendingPathComponent(Repo.pocketTts.folderName, isDirectory: true)
  }

  /// `<tts>/Models/pocket-tts/<subdir>/english` — the only language pack the
  /// plugin binds (TtsHostApiImpl.pocketCreate hardcodes `.english`).
  private func pocketTtsDirectory() throws -> URL {
    try pocketTtsRepoDirectory()
      .appendingPathComponent(PocketTtsLanguage.english.repoSubdirectory, isDirectory: true)
  }

  /// The directory `cacheDirectory` reports and `remove` clears for [kind].
  /// For the families with variants (EOU chunk sizes, Kokoro languages,
  /// PocketTTS language packs) `remove` deliberately takes the whole family —
  /// see `removeDirectories`.
  private func directory(for kind: ModelKindMessage) throws -> URL {
    switch kind {
    case .kokoro: return try kokoroDirectory()
    case .pocketTts: return try pocketTtsDirectory()
    case .vad, .parakeetV2, .parakeetV3, .eou, .diarizer, .ctc110m:
      return ModelPaths.repoDirectory(repo(for: kind))
    }
  }

  /// Every directory `remove` deletes for [kind].
  private func removeDirectories(for kind: ModelKindMessage) throws -> [URL] {
    switch kind {
    // For EOU, clear the whole family — every chunk variant plus any legacy
    // doubled-layout residue — not just the ms320 repo folder.
    case .eou:
      return [EouModelCache.eouDirectory]
    // Kokoro: every language variant (`kokoro-82m-coreml/*`) plus the shared
    // G2P assets, which are useless on their own once the voices are gone.
    case .kokoro:
      return [try kokoroDirectory().deletingLastPathComponent(), try kokoroG2pDirectory()]
    // PocketTTS: the whole repo folder, so any language pack a previous
    // version cached goes with it.
    case .pocketTts:
      return [try pocketTtsRepoDirectory()]
    case .vad, .parakeetV2, .parakeetV3, .diarizer, .ctc110m:
      return [try directory(for: kind)]
    }
  }

  private func allFilesExist(_ names: Set<String>, in directory: URL) -> Bool {
    names.allSatisfy { name in
      FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }
  }

  // MARK: - ModelsHostApi

  func isDownloaded(kind: ModelKindMessage, completion: @escaping (Result<Bool, Error>) -> Void) {
    if let version = asrVersion(for: kind) {
      let directory = ModelPaths.repoDirectory(repo(for: kind))
      completion(.success(AsrModels.modelsExist(at: directory, version: version)))
      return
    }
    do {
      switch kind {
      case .eou:
        completion(.success(EouModelCache.isDownloaded(repo(for: kind))))
      case .diarizer:
        let directory = try directory(for: kind)
        completion(.success(allFilesExist(ModelNames.OfflineDiarizer.requiredModels, in: directory)))
      case .ctc110m:
        // CtcModels also verifies vocab.json, which the required-model set omits.
        completion(.success(CtcModels.modelsExist(at: try directory(for: kind))))
      case .kokoro:
        // Both halves are needed: KokoroAneManager.initialize() loads the G2P
        // assets from cache only — it never downloads them itself.
        let voices = try kokoroDirectory()
        let g2p = try kokoroG2pDirectory()
        completion(
          .success(
            allFilesExist(ModelNames.KokoroAne.requiredModels, in: voices)
              && allFilesExist(ModelNames.G2P.requiredModels, in: g2p)))
      case .pocketTts:
        let directory = try directory(for: kind)
        completion(.success(allFilesExist(ModelNames.PocketTTS.requiredModels, in: directory)))
      case .vad, .parakeetV2, .parakeetV3:
        // VAD: the repo folder existing and being non-empty is the best public check.
        let directory = ModelPaths.repoDirectory(repo(for: kind))
        let contents =
          (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        completion(.success(!contents.isEmpty))
      }
    } catch {
      completion(.failure(ErrorMapping.map(error)))
    }
  }

  func download(
    kind: ModelKindMessage, progressToken: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        if let version = self.asrVersion(for: kind) {
          _ = try await AsrModels.download(
            to: ModelPaths.repoDirectory(self.repo(for: kind)),
            version: version, progressHandler: handler)
        } else {
          switch kind {
          case .eou:
            // Session-free download to the plugin's canonical EOU layout. The
            // cache-hit guard (which also migrates any legacy doubled-layout
            // cache) mirrors AsrModels.download: a present model is an instant
            // no-op with no network listing, and keeps working in offline mode.
            if !EouModelCache.isDownloaded(self.repo(for: kind)) {
              try await ModelHub.download(
                self.repo(for: kind), to: EouModelCache.modelsRoot, progressHandler: handler)
            }
          case .diarizer:
            // The "offline" variant is the file set OfflineDiarizerModels.load
            // asks for — FluidDiarizer's pipeline.
            try await ModelHub.download(
              .diarizer, to: ModelPaths.modelsRoot,
              variant: "offline", progressHandler: handler)
          case .ctc110m:
            // CtcModels.download has no ProgressHandler hook; emit coarse
            // phases so the Dart progress stream still resolves (same shape as
            // CtcVocabularyHostApiImpl.load).
            self.downloadProgress.emit(
              progressToken: progressToken,
              progress: DownloadProgress(fractionCompleted: 0.0, phase: .listing))
            _ = try await CtcModels.download(
              to: ModelPaths.repoDirectory(self.repo(for: kind)), variant: .ctc110m)
          case .kokoro:
            let kokoroModels = try self.ttsModelsRoot(
              KokoroAneResourceDownloader.modelsSubdirectory)
            _ = try await KokoroAneResourceDownloader.ensureModels(
              variant: .english, directory: kokoroModels, progressHandler: handler)
            // G2P must land in the default cache: the loader has no hook (see
            // kokoroG2pDirectory).
            try await KokoroAneResourceDownloader.ensureG2PAssets(
              progressHandler: handler)
          case .pocketTts:
            _ = try await PocketTtsResourceDownloader.ensureModels(
              language: .english, directory: try ModelPaths.ttsRoot(),
              progressHandler: handler)
          case .vad, .parakeetV2, .parakeetV3:
            // ModelHub downloads and compiles into the resolved models root —
            // the same load path VadHostApiImpl uses (VadManager's own default
            // init resolves a private root that ignores the override).
            _ = try await ModelHub.loadModels(
              .vad, modelNames: Array(ModelNames.VAD.requiredModels),
              directory: ModelPaths.modelsRoot,
              computeUnits: VadConfig.default.computeUnits,
              progressHandler: handler)
          }
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
    do {
      for directory in try removeDirectories(for: kind)
      where FileManager.default.fileExists(atPath: directory.path) {
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
    do {
      completion(.success(try directory(for: kind).path))
    } catch {
      completion(.failure(ErrorMapping.map(error)))
    }
  }

  func setOfflineMode(enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
    ModelHub.offlineMode = enabled
    completion(.success(()))
  }

  func setModelRoots(
    roots: ModelRootsMessage?, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    do {
      try ModelPaths.setRoots(
        models: (roots?.modelsRoot).map { URL(fileURLWithPath: $0, isDirectory: true) },
        tts: (roots?.ttsRoot).map { URL(fileURLWithPath: $0, isDirectory: true) })
      completion(.success(()))
    } catch let error as PigeonError {
      completion(.failure(error))
    } catch {
      completion(.failure(ErrorMapping.map(error)))
    }
  }

  func modelRoots(completion: @escaping (Result<ModelRootsMessage, Error>) -> Void) {
    do {
      let roots = try ModelPaths.currentRoots()
      completion(
        .success(ModelRootsMessage(modelsRoot: roots.models.path, ttsRoot: roots.tts.path)))
    } catch {
      completion(.failure(ErrorMapping.map(error)))
    }
  }
}
