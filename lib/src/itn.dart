import 'package:meta/meta.dart';

import 'exceptions.dart';
import 'messages.g.dart' as messages;

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

  /// Adds a custom spoken→written replacement rule.
  Future<void> addRule({required String spoken, required String written}) =>
      wrapPlatformErrors(() => _hostApi.addRule(spoken, written));

  Future<bool> removeRule(String spoken) =>
      wrapPlatformErrors(() => _hostApi.removeRule(spoken));

  Future<void> clearRules() => wrapPlatformErrors(() => _hostApi.clearRules());
}
