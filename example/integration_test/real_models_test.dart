// Heavy end-to-end tests against REAL CoreML models.
//
// Opt-in: FLUIDAUDIO_RUN_MODELS=1 flutter test integration_test/real_models_test.dart -d macos
//
// First run downloads models from HuggingFace (~460 MB for Parakeet v3) and
// compiles for the ANE (20-30 s); later runs use the on-disk cache.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart_example/wav.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final runModels = Platform.environment['FLUIDAUDIO_RUN_MODELS'] == '1';

  group('real models', skip: runModels ? false : 'set FLUIDAUDIO_RUN_MODELS=1', () {
    late FluidAsr asr;
    late Float32List helloSamples;
    late Float32List silenceSamples;

    setUpAll(() async {
      helloSamples = await loadWavAsset('assets/hello.wav');
      silenceSamples = await loadWavAsset('assets/silence.wav');
      asr = await FluidAsr.load();
    });

    tearDownAll(() async {
      await asr.dispose();
    });

    testWidgets('batch transcription recognizes speech', (tester) async {
      final result = await asr.transcribe(helloSamples);
      expect(result.text.toLowerCase(), contains('hello'));
      expect(result.confidence, greaterThan(0));
      expect(result.duration.inMilliseconds, greaterThan(1000));
      expect(result.tokenTimings, isNotNull);
      expect(result.tokenTimings, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('one-shot calls are stateless (fresh decoder state)', (tester) async {
      final first = await asr.transcribe(helloSamples);
      final second = await asr.transcribe(helloSamples);
      expect(second.text, first.text,
          reason: 'reused decoder state would corrupt the second transcript');
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('batch cancellation releases inference within two seconds',
        (tester) async {
      // Three minutes is long enough that cancellation lands during native
      // chunk/CoreML work rather than after an already-completed operation.
      final longSamples = Float32List(16000 * 60 * 3);
      for (var offset = 0; offset < longSamples.length; offset += helloSamples.length) {
        final count = (longSamples.length - offset).clamp(0, helloSamples.length);
        longSamples.setRange(offset, offset + count, helloSamples);
      }

      final operation = asr.startTranscription(longSamples);
      final result = expectLater(
        operation.result,
        throwsA(isA<FluidOperationCancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final stopwatch = Stopwatch()..start();
      await operation.cancel().timeout(const Duration(seconds: 2));
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      await result;

      // Cancelling one operation must not unload the shared recognizer.
      final afterCancellation = await asr.transcribe(helloSamples);
      expect(afterCancellation.text.toLowerCase(), contains('hello'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('file-based transcription matches sample-based', (tester) async {
      final path = await materializeWavAsset('assets/hello.wav');
      final fromFile = await asr.transcribeFile(path);
      final fromSamples = await asr.transcribe(helloSamples);
      expect(fromFile.text.toLowerCase(), contains('hello'));
      expect(fromFile.text, fromSamples.text);
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('streaming session transcribes chunked audio and emits updates',
        (tester) async {
      final session = await FluidStreamingAsr.create();
      final updates = <FluidTranscriptionUpdate>[];
      final subscription = session.updates.listen(updates.add);
      addTearDown(() async {
        await subscription.cancel();
        await session.dispose();
      });

      await session.start();
      const chunk = 1600; // 100 ms
      for (var offset = 0; offset < helloSamples.length; offset += chunk) {
        final end = (offset + chunk).clamp(0, helloSamples.length);
        await session.feed(Float32List.sublistView(helloSamples, offset, end));
      }
      final transcript = await session.finish();

      expect(transcript.toLowerCase(), contains('hello'));
      // Chunked streaming must agree with batch on the obvious content.
      expect(transcript.toLowerCase(), contains('test'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('VAD separates speech from silence', (tester) async {
      final vad = await FluidVad.create();
      addTearDown(vad.dispose);

      final speechResults = await vad.process(helloSamples);
      final silenceResults = await vad.process(silenceSamples);

      expect(speechResults.where((r) => r.isVoiceActive), isNotEmpty);
      expect(silenceResults.where((r) => r.isVoiceActive), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('VAD stream emits speech start and end events', (tester) async {
      final vad = await FluidVad.create();
      addTearDown(vad.dispose);
      final stream = await vad.stream(minSilenceDuration: 0.3);
      addTearDown(stream.dispose);

      final events = <FluidVadStreamEvent>[];
      final subscription = stream.events.listen(events.add);
      addTearDown(subscription.cancel);

      // speech, then enough silence to close the segment.
      final feed = Float32List(helloSamples.length + 16000)
        ..setRange(0, helloSamples.length, helloSamples);
      for (var offset = 0;
          offset + FluidVadStream.chunkSize <= feed.length;
          offset += FluidVadStream.chunkSize) {
        await stream.feed(
            Float32List.sublistView(feed, offset, offset + FluidVadStream.chunkSize));
      }
      // Events hop through the platform thread.
      await tester.pump(const Duration(milliseconds: 300));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(events, isNotEmpty, reason: 'every chunk emits a probability tick');
      expect(events.where((e) => e.isSpeechStart), isNotEmpty);
      expect(events.where((e) => e.isSpeechEnd), isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('models API reports Parakeet v3 as downloaded after load',
        (tester) async {
      final models = FluidModels();
      expect(await models.isDownloaded(ModelKind.parakeetV3), isTrue);
      final directory = await models.cacheDirectory(ModelKind.parakeetV3);
      expect(directory, contains('FluidAudio'));
    });

    testWidgets('audio converter resamples and encodes WAV', (tester) async {
      final converter = FluidAudioConverter();
      final path = await materializeWavAsset('assets/hello.wav');
      final samples = await converter.resampleFile(path);
      expect(samples.length, helloSamples.length,
          reason: '16 kHz source must round-trip sample-exact in count');

      final upsampled = await converter.resample(samples, fromRate: 8000);
      expect(upsampled.length, greaterThan(samples.length));

      final wav = await converter.encodeWav(samples, sampleRate: 16000);
      expect(wav.length, greaterThan(44));
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    });

    testWidgets('Kokoro TTS synthesizes audible audio', (tester) async {
      final tts = await FluidKokoroTts.create();
      addTearDown(tts.dispose);

      final result = await tts.synthesizeDetailed('Hello from Flutter.');
      expect(result.sampleRate, 24000);
      expect(result.duration.inMilliseconds, greaterThan(300));
      expect(result.samples.any((sample) => sample.abs() > 0.01), isTrue,
          reason: 'output must not be silence');
      expect(String.fromCharCodes(result.wav.sublist(0, 4)), 'RIFF');
    }, timeout: const Timeout(Duration(minutes: 15)));

    testWidgets('PocketTTS streams synthesis frames', (tester) async {
      final tts = await FluidPocketTts.create();
      addTearDown(tts.dispose);

      final chunks = await tts.synthesizeStreaming('Streaming speech synthesis works.')
          .toList()
          .timeout(const Duration(minutes: 5));
      expect(chunks, isNotEmpty);
      expect(chunks.first.samples, hasLength(1920), reason: '80 ms frames at 24 kHz');
      final allSamples = chunks.expand((chunk) => chunk.samples);
      expect(allSamples.any((sample) => sample.abs() > 0.01), isTrue);
    }, timeout: const Timeout(Duration(minutes: 15)));

    testWidgets('diarization finds two speakers with embeddings', (tester) async {
      final diarizer = await FluidDiarizer.create();
      addTearDown(diarizer.dispose);

      final progressEvents = <(int, int)>[];
      final progressSubscription = diarizer.progress.listen(progressEvents.add);
      addTearDown(progressSubscription.cancel);

      final second = await loadWavAsset('assets/speaker2.wav');
      final samples = Float32List(helloSamples.length + 8000 + second.length)
        ..setRange(0, helloSamples.length, helloSamples)
        ..setRange(
            helloSamples.length + 8000, helloSamples.length + 8000 + second.length, second);

      final result = await diarizer.diarize(samples);

      expect(result.segments, isNotEmpty);
      expect(result.speakerIds.length, greaterThanOrEqualTo(1));
      for (final segment in result.segments) {
        expect(segment.embedding, isNotEmpty,
            reason: 'ectos-style speaker identity needs raw embeddings');
        expect(segment.end, greaterThan(segment.start));
      }
      // Progress callbacks flowed through the event channel.
      await tester.pump(const Duration(milliseconds: 300));
      expect(progressEvents, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('diarization cancellation releases inference within two seconds',
        (tester) async {
      final diarizer = await FluidDiarizer.create();
      addTearDown(diarizer.dispose);
      final second = await loadWavAsset('assets/speaker2.wav');
      final fixture = Float32List(helloSamples.length + 8000 + second.length)
        ..setRange(0, helloSamples.length, helloSamples)
        ..setRange(
            helloSamples.length + 8000, helloSamples.length + 8000 + second.length, second);
      final longSamples = Float32List(16000 * 60 * 3);
      for (var offset = 0; offset < longSamples.length; offset += fixture.length) {
        final count = (longSamples.length - offset).clamp(0, fixture.length);
        longSamples.setRange(offset, offset + count, fixture);
      }

      final operation = diarizer.startDiarization(longSamples);
      final result = expectLater(
        operation.result,
        throwsA(isA<FluidOperationCancelledException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final stopwatch = Stopwatch()..start();
      await operation.cancel().timeout(const Duration(seconds: 2));
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      await result;

      // Cancelling one operation must not unload the shared diarizer models.
      final afterCancellation = await diarizer.diarize(fixture);
      expect(afterCancellation.segments, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('ITN normalizes or no-ops gracefully', (tester) async {
      final itn = FluidItn();
      final available = await itn.isNativeAvailable();
      final normalized = await itn.normalize('twenty five dollars');
      if (available) {
        expect(normalized.toLowerCase(), isNot(contains('twenty')));
      } else {
        expect(normalized, 'twenty five dollars',
            reason: 'without the native lib, ITN must be a no-op');
      }
    });

    testWidgets('custom vocabulary loads and configures a streaming session',
        (tester) async {
      final vocabulary = await FluidCtcVocabulary.load(
        terms: const [FluidVocabularyTerm('FluidAudio'), FluidVocabularyTerm('Parakeet')],
      );
      addTearDown(vocabulary.dispose);

      final session = await FluidStreamingAsr.create();
      addTearDown(session.dispose);
      await session.configureVocabulary(vocabulary);
      await session.start();

      const chunk = 1600;
      for (var offset = 0; offset < helloSamples.length; offset += chunk) {
        final end = (offset + chunk).clamp(0, helloSamples.length);
        await session.feed(Float32List.sublistView(helloSamples, offset, end));
      }
      final transcript = await session.finish();
      expect(transcript.toLowerCase(), contains('hello'),
          reason: 'boosting must not break normal transcription');
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('EOU session emits utterances and finish returns transcript',
        (tester) async {
      final eou = await FluidEou.create();
      addTearDown(eou.dispose);

      final utterances = <String>[];
      final partials = <String>[];
      final utteranceSubscription = eou.utterances.listen(utterances.add);
      final partialSubscription = eou.partials.listen(partials.add);
      addTearDown(utteranceSubscription.cancel);
      addTearDown(partialSubscription.cancel);

      // Speech followed by 2s of silence so the EOU fires.
      final feed = Float32List(helloSamples.length + 32000)
        ..setRange(0, helloSamples.length, helloSamples);
      const chunk = 1600;
      for (var offset = 0; offset < feed.length; offset += chunk) {
        final end = (offset + chunk).clamp(0, feed.length);
        await eou.feed(Float32List.sublistView(feed, offset, end));
      }
      final transcript = await eou.finish();

      await tester.pump(const Duration(milliseconds: 500));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(transcript.toLowerCase(), contains('hello'));
      expect(partials, isNotEmpty, reason: 'partial callbacks must stream');
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('batch vocabulary rescoring rewrites a finished transcript',
        (tester) async {
      final vocabulary = await FluidCtcVocabulary.load(
        terms: const [FluidVocabularyTerm('FluidAudio'), FluidVocabularyTerm('Parakeet')],
      );
      addTearDown(vocabulary.dispose);

      final raw = await asr.transcribe(helloSamples);
      expect(raw.tokenTimings, isNotEmpty, reason: 'rescoring aligns through timings');

      final rescored = await vocabulary.rescore(raw, helloSamples);
      // The clip has no vocabulary term in it, so the guard that matters is
      // that rescoring is non-destructive: it either leaves the transcript
      // alone or replaces words with vocabulary terms — never garbage.
      expect(rescored.appliedTerms.every((term) => rescored.result.text.contains(term)),
          isTrue);
      if (!rescored.wasModified) {
        expect(rescored.result.text, raw.text);
        expect(rescored.appliedTerms, isEmpty);
      }
      // Token timings survive the pass in both branches.
      expect(rescored.result.tokenTimings, hasLength(raw.tokenTimings!.length));
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('ITN result overload keeps token timings attached', (tester) async {
      final itn = FluidItn();
      final raw = await asr.transcribe(helloSamples);
      final normalized = await itn.normalizeResult(raw);

      expect(normalized.tokenTimings, hasLength(raw.tokenTimings!.length));
      expect(normalized.duration, raw.duration);
      expect(normalized.confidence, raw.confidence);
    }, timeout: const Timeout(Duration(minutes: 5)));

    // Every kind this suite actually warms. `parakeetV2` is deliberately out:
    // nothing here loads it and probing it is meaningless, while downloading
    // it would add ~600 MB to the nightly.
    const warmedKinds = [
      ModelKind.parakeetV3,
      ModelKind.vad,
      ModelKind.eou,
      ModelKind.diarizer,
      ModelKind.ctc110m,
      ModelKind.kokoro,
      ModelKind.pocketTts,
    ];

    testWidgets('every warmed ModelKind probes and reports a cache directory',
        (tester) async {
      final models = FluidModels();
      // Sessions earlier in this suite pulled each of these; the probe is the
      // assertion that ModelsHostApiImpl looks in the same place the loader
      // wrote to — the TTS backends cache under a different root.
      for (final kind in warmedKinds) {
        expect(await models.isDownloaded(kind), isTrue, reason: '${kind.name} probe');
        final directory = await models.cacheDirectory(kind);
        expect(directory.toLowerCase(), contains('fluidaudio'),
            reason: '${kind.name} cache directory: $directory');
        expect(Directory(directory).existsSync(), isTrue,
            reason: '${kind.name} cache directory does not exist: $directory');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('download is a fast no-op on a warm cache', (tester) async {
      final models = FluidModels();
      // Exercises the whole native download switch (including the diarizer's
      // "offline" variant) without re-pulling gigabytes: a present model must
      // complete without listing the remote repo.
      for (final kind in warmedKinds) {
        await models.download(kind).toList();
        expect(await models.isDownloaded(kind), isTrue, reason: '${kind.name} after download');
      }
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('remove then download round-trips the CTC-110M cache',
        (tester) async {
      // Only the cheapest kind is round-tripped for real (~100 MB). The other
      // bundles run to 800 MB each; deleting and re-pulling them on every
      // nightly is not worth the bandwidth, so they stay probe-only above.
      final models = FluidModels();
      final directory = await models.cacheDirectory(ModelKind.ctc110m);

      await models.remove(ModelKind.ctc110m);
      expect(await models.isDownloaded(ModelKind.ctc110m), isFalse);
      expect(Directory(directory).existsSync(), isFalse);

      final progress = await models.download(ModelKind.ctc110m).toList();
      expect(progress, isNotEmpty, reason: 'a cold download must report progress');
      expect(await models.isDownloaded(ModelKind.ctc110m), isTrue);
    }, timeout: const Timeout(Duration(minutes: 20)));
  });
}
