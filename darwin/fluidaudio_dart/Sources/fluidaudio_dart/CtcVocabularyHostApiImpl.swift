import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// A tokenized custom vocabulary plus the CTC models that back its spotter.
final class CtcVocabularyInstance {
  let context: CustomVocabularyContext
  let models: CtcModels

  init(context: CustomVocabularyContext, models: CtcModels) {
    self.context = context
    self.models = models
  }
}

final class CtcVocabularyHostApiImpl: CtcVocabularyHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler

  init(registry: InstanceRegistry, downloadProgress: DownloadProgressHandler) {
    self.registry = registry
    self.downloadProgress = downloadProgress
  }

  func load(
    terms: [VocabularyTermMessage], minSimilarity: Double, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    Task {
      do {
        // CtcModels has no ProgressHandler hook; emit coarse phases so the
        // Dart progress stream still resolves.
        self.downloadProgress.emit(
          progressToken: progressToken,
          progress: DownloadProgress(fractionCompleted: 0.0, phase: .listing))
        let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load()

        let vocabularyTerms = terms.map { term in
          CustomVocabularyTerm(
            text: term.text,
            weight: term.weight.map(Float.init),
            aliases: term.aliases,
            ctcTokenIds: tokenizer.encode(term.text)
          )
        }
        let context = CustomVocabularyContext(
          terms: vocabularyTerms,
          minSimilarity: Float(minSimilarity)
        )

        let id = self.registry.add(CtcVocabularyInstance(context: context, models: models))
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    registry.remove(instanceId)
    completion(.success(()))
  }
}
