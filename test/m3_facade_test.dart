import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/audio_bytes.dart';
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

  messages.AsrResultMessage? rescoredResult;
  Uint8List? rescoredSamples;
  double? rescoreWeight;

  @override
  Future<int> load(List<messages.VocabularyTermMessage> terms, double minSimilarity,
      int progressToken) async {
    this.terms = terms;
    this.minSimilarity = minSimilarity;
    return 51;
  }

  @override
  Future<messages.VocabularyRescoreMessage> rescoreResult(
    int instanceId,
    messages.AsrResultMessage result,
    Uint8List float32Samples,
    double defaultWeight,
  ) async {
    rescoredResult = result;
    rescoredSamples = float32Samples;
    rescoreWeight = defaultWeight;
    return messages.VocabularyRescoreMessage(
      result: messages.AsrResultMessage(
        text: 'call fluidaudio',
        confidence: result.confidence,
        durationSeconds: result.durationSeconds,
        processingSeconds: result.processingSeconds,
        tokenTimings: result.tokenTimings,
      ),
      wasModified: true,
      detectedTerms: ['FluidAudio'],
      appliedTerms: ['fluidaudio'],
    );
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

  messages.AsrResultMessage? normalizedResult;

  @override
  Future<messages.AsrResultMessage> normalizeResult(messages.AsrResultMessage result) async {
    normalizedResult = result;
    return messages.AsrResultMessage(
      text: result.text.replaceAll('twenty five', '25'),
      confidence: result.confidence,
      durationSeconds: result.durationSeconds,
      processingSeconds: result.processingSeconds,
      tokenTimings: result.tokenTimings,
    );
  }

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

  test('FluidCtcVocabulary.rescore round-trips a finished transcription',
      () async {
    final fake = _FakeCtcVocabularyHostApi();
    final vocabulary = await FluidCtcVocabulary.load(
      terms: const [FluidVocabularyTerm('FluidAudio')],
      hostApi: fake,
      events: FluidEventHub.test(downloadProgress: const Stream.empty()),
    );

    final samples = Float32List.fromList([0.1, -0.2, 0.3]);
    final rescored = await vocabulary.rescore(
      const FluidAsrResult(
        text: 'call fluid audio',
        confidence: 0.9,
        duration: Duration(seconds: 2),
        processingTime: Duration(milliseconds: 250),
        tokenTimings: [
          FluidTokenTiming(
            token: '▁call',
            tokenId: 7,
            start: Duration.zero,
            end: Duration(milliseconds: 400),
            confidence: 0.8,
          ),
        ],
      ),
      samples,
    );

    // The audio and the result cross the channel unchanged; the weight
    // defaults to the batch route's aggressive 10.0 (Ectos's value).
    expect(fake.rescoreWeight, 10.0);
    expect(fake.rescoredSamples, floatsToBytes(samples));
    expect(fake.rescoredResult!.text, 'call fluid audio');
    expect(fake.rescoredResult!.durationSeconds, 2.0);
    expect(fake.rescoredResult!.tokenTimings!.single.token, '▁call');
    expect(fake.rescoredResult!.tokenTimings!.single.endSeconds, 0.4);

    expect(rescored.wasModified, isTrue);
    expect(rescored.result.text, 'call fluidaudio');
    expect(rescored.detectedTerms, ['FluidAudio']);
    expect(rescored.appliedTerms, ['fluidaudio']);
    // Timings survive the rescoring pass.
    expect(rescored.result.tokenTimings!.single.end, const Duration(milliseconds: 400));
  });

  test('FluidCtcVocabulary.rescore honours an explicit weight', () async {
    final fake = _FakeCtcVocabularyHostApi();
    final vocabulary = await FluidCtcVocabulary.load(
      terms: const [FluidVocabularyTerm('ectos')],
      hostApi: fake,
      events: FluidEventHub.test(downloadProgress: const Stream.empty()),
    );

    await vocabulary.rescore(
      const FluidAsrResult(
        text: 'ectosis',
        confidence: 1,
        duration: Duration(seconds: 1),
        processingTime: Duration(milliseconds: 100),
      ),
      Float32List(4),
      weight: 3.0,
    );

    expect(fake.rescoreWeight, 3.0);
  });

  test('FluidItn.normalizeResult keeps the token timings attached', () async {
    final fake = _FakeItnHostApi();
    final itn = FluidItn(hostApi: fake);

    final normalized = await itn.normalizeResult(const FluidAsrResult(
      text: 'twenty five dollars',
      confidence: 0.75,
      duration: Duration(milliseconds: 1500),
      processingTime: Duration(milliseconds: 120),
      tokenTimings: [
        FluidTokenTiming(
          token: '▁twenty',
          tokenId: 3,
          start: Duration(milliseconds: 100),
          end: Duration(milliseconds: 500),
          confidence: 0.7,
        ),
      ],
    ));

    expect(fake.normalizedResult!.durationSeconds, 1.5);
    expect(fake.normalizedResult!.tokenTimings!.single.startSeconds, 0.1);

    expect(normalized.text, '25 dollars');
    expect(normalized.confidence, 0.75);
    expect(normalized.duration, const Duration(milliseconds: 1500));
    expect(normalized.tokenTimings!.single.token, '▁twenty');
    expect(normalized.tokenTimings!.single.start, const Duration(milliseconds: 100));
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
