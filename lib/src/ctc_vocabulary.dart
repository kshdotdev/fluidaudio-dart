import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'types.dart';

/// A term to boost in transcription output.
class FluidVocabularyTerm {
  const FluidVocabularyTerm(this.text, {this.weight, this.aliases});

  final String text;

  /// Context-biasing weight for this term. When null,
  /// [FluidCtcVocabulary.rescore]'s `weight` applies.
  final double? weight;

  final List<String>? aliases;
}

/// The outcome of [FluidCtcVocabulary.rescore].
class FluidVocabularyRescore {
  const FluidVocabularyRescore({
    required this.result,
    required this.wasModified,
    required this.detectedTerms,
    required this.appliedTerms,
  });

  /// The rescored transcription, or the input unchanged when
  /// [wasModified] is false.
  final FluidAsrResult result;

  final bool wasModified;

  /// Terms the CTC spotter found in the audio (replacement candidates).
  final List<String> detectedTerms;

  /// Terms actually written into [result].
  final List<String> appliedTerms;
}

/// A custom vocabulary for boosting domain terms (names, jargon), backed by
/// the CTC-110M keyword spotter.
///
/// Two routes use it:
/// - streaming — pass to `FluidStreamingAsr.configureVocabulary` before
///   starting the stream; terms are boosted while decoding;
/// - batch — [rescore] a finished `FluidAsr.transcribe` result against the
///   same audio; there is no decoding left to bias, so the spotter's CTC
///   log-probabilities are used to rewrite low-confidence words instead.
class FluidCtcVocabulary {
  FluidCtcVocabulary._(this._hostApi, this.instanceId);

  final messages.CtcVocabularyHostApi _hostApi;

  /// Channel-visible id; used by [FluidStreamingAsr.configureVocabulary].
  final int instanceId;

  bool _disposed = false;

  /// Downloads/loads the CTC-110M models (~100 MB, cached) and tokenizes
  /// [terms].
  static Future<FluidCtcVocabulary> load({
    required List<FluidVocabularyTerm> terms,
    double minSimilarity = 0.85,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.CtcVocabularyHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.CtcVocabularyHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(
        () => api.load(
          [
            for (final term in terms)
              messages.VocabularyTermMessage(
                  text: term.text, weight: term.weight, aliases: term.aliases),
          ],
          minSimilarity,
          token,
        ),
      );
      return FluidCtcVocabulary._(api, id);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Rescores a finished batch transcription against this vocabulary.
  ///
  /// [samples] must be the same 16 kHz mono float32 audio [result] was
  /// transcribed from: the CTC spotter re-runs over it to obtain the
  /// log-probabilities that decide whether a vocabulary term has more
  /// acoustic evidence than the word the decoder emitted. [weight] is the
  /// context-biasing weight for terms loaded without their own
  /// ([FluidVocabularyTerm.weight]); 10.0 is the aggressive default the batch
  /// route uses.
  ///
  /// [result] must carry [FluidAsrResult.tokenTimings] — replacements are
  /// aligned through them. Without timings (or when nothing beat the
  /// original transcript) the input is returned with
  /// [FluidVocabularyRescore.wasModified] false. The timings are carried
  /// through untouched: replacements are word-for-word, so the original
  /// alignment stays valid.
  Future<FluidVocabularyRescore> rescore(
    FluidAsrResult result,
    Float32List samples, {
    double weight = 10.0,
  }) async {
    final rescored = await wrapPlatformErrors(
      () => _hostApi.rescoreResult(
        instanceId,
        asrResultMessage(result),
        floatsToBytes(samples),
        weight,
      ),
    );
    return FluidVocabularyRescore(
      result: mapAsrResult(rescored.result),
      wasModified: rescored.wasModified,
      detectedTerms: rescored.detectedTerms,
      appliedTerms: rescored.appliedTerms,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await wrapPlatformErrors(() => _hostApi.dispose(instanceId));
  }
}
