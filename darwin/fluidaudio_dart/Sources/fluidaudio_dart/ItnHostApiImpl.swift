import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Inverse text normalization ("twenty five dollars" → "$25").
///
/// Backed by FluidAudio's `TextNormalizer`; when the native NeMo library is
/// not loadable, every call is a graceful no-op returning the input.
final class ItnHostApiImpl: ItnHostApi {
  private let normalizer = TextNormalizer.shared

  func isNativeAvailable(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(normalizer.isNativeAvailable))
  }

  func normalize(text: String, completion: @escaping (Result<String, Error>) -> Void) {
    completion(.success(normalizer.normalize(text)))
  }

  func normalizeSentence(
    text: String, maxSpanTokens: Int64?,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    if let maxSpanTokens {
      completion(.success(normalizer.normalizeSentence(text, maxSpanTokens: UInt32(maxSpanTokens))))
    } else {
      completion(.success(normalizer.normalizeSentence(text)))
    }
  }

  /// `TextNormalizer.normalize(result:)` — rewrites the text in sentence mode
  /// while carrying the token timings through unchanged, so ITN and word
  /// timings can coexist. Returns the input when normalization is a no-op.
  func normalizeResult(
    result: AsrResultMessage, completion: @escaping (Result<AsrResultMessage, Error>) -> Void
  ) {
    let normalized = normalizer.normalize(result: TypeMapping.asrResult(from: result))
    guard normalized.text != result.text else {
      completion(.success(result))
      return
    }
    // Round-trip through the message we were given rather than the mapped
    // ASRResult, so nothing the wire format does not carry is invented.
    completion(
      .success(
        AsrResultMessage(
          text: normalized.text,
          confidence: result.confidence,
          durationSeconds: result.durationSeconds,
          processingSeconds: result.processingSeconds,
          tokenTimings: result.tokenTimings
        )))
  }

  func addRule(
    spoken: String, written: String, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    normalizer.addRule(spoken: spoken, written: written)
    completion(.success(()))
  }

  func removeRule(spoken: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(normalizer.removeRule(spoken: spoken)))
  }

  func clearRules(completion: @escaping (Result<Void, Error>) -> Void) {
    normalizer.clearRules()
    completion(.success(()))
  }
}
