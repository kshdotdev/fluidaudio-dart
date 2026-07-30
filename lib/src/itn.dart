import 'package:meta/meta.dart';

import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'types.dart';

/// Inverse text normalization: spoken → written form
/// ("twenty five dollars" → "$25").
///
/// When the native normalization library is unavailable at runtime, all calls
/// are no-ops returning the input unchanged — check [isNativeAvailable].
class FluidItn {
  FluidItn({@visibleForTesting messages.ItnHostApi? hostApi})
      : _hostApi = hostApi ?? messages.ItnHostApi();

  final messages.ItnHostApi _hostApi;

  Future<bool> isNativeAvailable() =>
      wrapPlatformErrors(() => _hostApi.isNativeAvailable());

  /// Normalizes a single spoken-form expression.
  Future<String> normalize(String text) =>
      wrapPlatformErrors(() => _hostApi.normalize(text));

  /// Sliding-window normalization across a full sentence.
  Future<String> normalizeSentence(String text, {int? maxSpanTokens}) =>
      wrapPlatformErrors(() => _hostApi.normalizeSentence(text, maxSpanTokens));

  /// Normalizes a whole transcription in sentence mode, keeping
  /// [FluidAsrResult.tokenTimings] attached — the one path where ITN and word
  /// timings coexist ([normalizeSentence] only takes bare strings, so callers
  /// lose the alignment).
  ///
  /// The timings are carried through untouched: normalization rewrites spans
  /// in place (e.g. "twenty five dollars" → "$25"), so a timing still points
  /// at the audio its token came from, but a rewritten span's token count no
  /// longer matches the text. Use the timings for coarse alignment (segment
  /// boundaries), not to index into the normalized string.
  ///
  /// Returns [result] unchanged when normalization is a no-op — including
  /// when the native library is unavailable ([isNativeAvailable]).
  Future<FluidAsrResult> normalizeResult(FluidAsrResult result) async {
    final normalized = await wrapPlatformErrors(
        () => _hostApi.normalizeResult(asrResultMessage(result)));
    return mapAsrResult(normalized);
  }

  /// Adds a custom spoken→written replacement rule.
  Future<void> addRule({required String spoken, required String written}) =>
      wrapPlatformErrors(() => _hostApi.addRule(spoken, written));

  Future<bool> removeRule(String spoken) =>
      wrapPlatformErrors(() => _hostApi.removeRule(spoken));

  Future<void> clearRules() => wrapPlatformErrors(() => _hostApi.clearRules());
}
