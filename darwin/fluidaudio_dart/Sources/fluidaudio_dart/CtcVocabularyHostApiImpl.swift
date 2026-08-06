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
        let ctcDirectory = ModelPaths.repoDirectory(CtcModelVariant.ctc110m.repo)
        let models = try await CtcModels.downloadAndLoad(
          to: ctcDirectory, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: ctcDirectory)
        // Upstream streaming vocabulary boosting re-resolves the tokenizer
        // from the DEFAULT cache with no directory hook
        // (SlidingWindowAsrManager.configureVocabularyBoosting), so mirror
        // tokenizer.json there when a host models root is active.
        let defaultDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        if defaultDirectory.path != ctcDirectory.path {
          let fileManager = FileManager.default
          try fileManager.createDirectory(
            at: defaultDirectory, withIntermediateDirectories: true)
          let source = ctcDirectory.appendingPathComponent("tokenizer.json")
          let target = defaultDirectory.appendingPathComponent("tokenizer.json")
          if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
          }
          try fileManager.copyItem(at: source, to: target)
        }
        ModelPaths.registerInstanceCreated()

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

  /// Batch counterpart to `StreamingAsrHostApi.configureVocabulary`: spot the
  /// vocabulary in the already-transcribed audio and rewrite low-confidence
  /// words against it, reusing this instance's loaded CTC models (the streaming
  /// route boosts during decoding; a finished transcript can only be rescored).
  func rescoreResult(
    instanceId: Int64, result: AsrResultMessage, float32Samples: FlutterStandardTypedData,
    defaultWeight: Double, completion: @escaping (Result<VocabularyRescoreMessage, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: CtcVocabularyInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "CTC vocabulary")))
      return
    }
    // Rescoring aligns replacements against the transcript's own token
    // timings; without them there is nothing to anchor to.
    guard let timings = result.tokenTimings, !timings.isEmpty else {
      completion(.success(Self.unchanged(result)))
      return
    }
    let samples = AudioBridge.floats(from: float32Samples)
    let context = Self.applyingDefaultWeight(Float(defaultWeight), to: instance.context)
    Task {
      do {
        let spotter = CtcKeywordSpotter(models: instance.models)
        let rescorer = try await VocabularyRescorer.create(
          spotter: spotter,
          vocabulary: context,
          ctcModelDirectory: ModelPaths.repoDirectory(instance.models.variant.repo)
        )
        let spot = try await spotter.spotKeywordsWithLogProbs(
          audioSamples: samples, customVocabulary: context)
        let rescored = rescorer.ctcTokenRescore(
          transcript: result.text,
          tokenTimings: timings.map(TypeMapping.tokenTiming(from:)),
          logProbs: spot.logProbs,
          frameDuration: spot.frameDuration
        )
        guard rescored.wasModified else {
          completion(.success(Self.unchanged(result)))
          return
        }
        // Replacements are word-for-word, so the original token timings stay
        // valid — carry them through untouched.
        completion(
          .success(
            VocabularyRescoreMessage(
              result: AsrResultMessage(
                text: rescored.text,
                confidence: result.confidence,
                durationSeconds: result.durationSeconds,
                processingSeconds: result.processingSeconds,
                tokenTimings: result.tokenTimings
              ),
              wasModified: true,
              detectedTerms: spot.detections.map(\.term.text),
              appliedTerms: rescored.replacements.filter(\.shouldReplace).compactMap(
                \.replacementWord)
            )))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    registry.remove(instanceId)
    completion(.success(()))
  }

  private static func unchanged(_ result: AsrResultMessage) -> VocabularyRescoreMessage {
    VocabularyRescoreMessage(
      result: result, wasModified: false, detectedTerms: [], appliedTerms: [])
  }

  /// Terms loaded without an explicit weight get [weight] — the flat
  /// context-biasing weight the batch route uses (10.0 in Ectos).
  private static func applyingDefaultWeight(
    _ weight: Float, to context: CustomVocabularyContext
  ) -> CustomVocabularyContext {
    CustomVocabularyContext(
      terms: context.terms.map { term in
        CustomVocabularyTerm(
          text: term.text,
          weight: term.weight ?? weight,
          aliases: term.aliases,
          tokenIds: term.tokenIds,
          ctcTokenIds: term.ctcTokenIds,
          minSimilarity: term.minSimilarity
        )
      },
      alpha: context.alpha,
      minCtcScore: context.minCtcScore,
      minSimilarity: context.minSimilarity,
      minCombinedConfidence: context.minCombinedConfidence,
      minTermLength: context.minTermLength
    )
  }
}
