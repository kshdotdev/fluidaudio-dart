import 'package:meta/meta.dart';

import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'types.dart';

/// A term to boost in transcription output.
class FluidVocabularyTerm {
  const FluidVocabularyTerm(this.text, {this.weight, this.aliases});

  final String text;
  final double? weight;
  final List<String>? aliases;
}

/// A custom vocabulary for boosting domain terms (names, jargon) during
/// streaming transcription, backed by the CTC-110M keyword spotter.
///
/// Pass to [FluidStreamingAsr.configureVocabulary] before starting the stream.
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await wrapPlatformErrors(() => _hostApi.dispose(instanceId));
  }
}
