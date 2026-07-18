import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/events.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

class _FakeCtcVocabularyHostApi implements messages.CtcVocabularyHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  List<messages.VocabularyTermMessage>? terms;
  double? minSimilarity;

  @override
  Future<int> load(List<messages.VocabularyTermMessage> terms, double minSimilarity,
      int progressToken) async {
    this.terms = terms;
    this.minSimilarity = minSimilarity;
    return 51;
  }

  @override
  Future<void> dispose(int instanceId) async {}
}

class _FakeItnHostApi implements messages.ItnHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  final rules = <String, String>{};

  @override
  Future<bool> isNativeAvailable() async => true;

  @override
  Future<String> normalize(String text) async => text.replaceAll('twenty five', '25');

  @override
  Future<String> normalizeSentence(String text, int? maxSpanTokens) async =>
      '$text [span=$maxSpanTokens]';

  @override
  Future<void> addRule(String spoken, String written) async {
    rules[spoken] = written;
  }

  @override
  Future<bool> removeRule(String spoken) async => rules.remove(spoken) != null;

  @override
  Future<void> clearRules() async => rules.clear();
}

void main() {
  test('FluidCtcVocabulary.load passes tokenizable terms', () async {
    final fake = _FakeCtcVocabularyHostApi();
    final hub = FluidEventHub.test(downloadProgress: const Stream.empty());
    final vocabulary = await FluidCtcVocabulary.load(
      terms: const [
        FluidVocabularyTerm('FluidAudio', weight: 2.0),
        FluidVocabularyTerm('ectos', aliases: ['ecto']),
      ],
      minSimilarity: 0.9,
      hostApi: fake,
      events: hub,
    );

    expect(vocabulary.instanceId, 51);
    expect(fake.minSimilarity, 0.9);
    expect(fake.terms, hasLength(2));
    expect(fake.terms![0].text, 'FluidAudio');
    expect(fake.terms![0].weight, 2.0);
    expect(fake.terms![1].aliases, ['ecto']);
  });

  test('FluidItn forwards calls and rules', () async {
    final fake = _FakeItnHostApi();
    final itn = FluidItn(hostApi: fake);

    expect(await itn.isNativeAvailable(), isTrue);
    expect(await itn.normalize('twenty five dollars'), '25 dollars');
    expect(await itn.normalizeSentence('hi', maxSpanTokens: 4), 'hi [span=4]');

    await itn.addRule(spoken: 'brb', written: 'be right back');
    expect(fake.rules, {'brb': 'be right back'});
    expect(await itn.removeRule('brb'), isTrue);
    expect(await itn.removeRule('brb'), isFalse);
  });
}
