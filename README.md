# fluidaudio_dart

Flutter bindings for [FluidAudio](https://github.com/FluidInference/FluidAudio) —
on-device speech-to-text, voice activity detection, speaker diarization and
text-to-speech on Apple platforms, powered by CoreML and the Apple Neural Engine.

> **Status: feature-complete against FluidAudio 0.15.x.** Batch + streaming
> speech-to-text, VAD, speaker diarization (with embeddings), end-of-utterance
> turn detection, custom-vocabulary boosting (streaming *and* batch
> rescoring), inverse text normalization (with or without word timings),
> text-to-speech (Kokoro + PocketTTS incl. streaming and voice cloning), audio
> conversion, and model management for every loadable bundle — all verified
> end-to-end against real CoreML models. Native microphone / system-audio
> capture ships too but is deprecated in favour of `package:audio_flutter`
> (see [Capture ownership](#capture-ownership)). API may still change
> before 1.0.

```dart
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

final asr = await FluidAsr.load(); // downloads Parakeet v3 on first use
final result = await asr.transcribe(samples16kHzMonoFloat32);
print(result.text);

// Live mic dictation with partial/confirmed updates:
final session = await FluidStreamingAsr.create();
session.updates.listen((u) => print('${u.isConfirmed ? "✓" : "…"} ${u.text}'));
await session.start();
await FluidMicrophone().start(transcribers: [session]); // native capture
// ... later:
final transcript = await session.finish();
```

## Recipes

```dart
// Voice activity detection — batch and streaming
final vad = await FluidVad.create();
final results = await vad.process(samples);            // per-4096-sample chunks
final stream = await vad.stream(minSilenceDuration: 0.3);
stream.events.listen((e) { /* e.probability, e.isSpeechStart, e.isSpeechEnd */ });

// Speaker diarization with raw embeddings (cross-recording identity)
final diarizer = await FluidDiarizer.create(maxSpeakers: 4);
final result = await diarizer.diarizeFile('/path/to/meeting.wav');
for (final s in result.segments) {
  print('${s.speakerId} ${s.start}–${s.end}  embedding=${s.embedding.length}d');
}

// End-of-utterance turn detection (live)
final eou = await FluidEou.create();
eou.partials.listen((text) => print('… $text'));
eou.utterances.listen((text) => print('turn ended: $text'));
await FluidMicrophone().start(turnDetectors: [eou]);

// Boost domain terms during streaming transcription
final vocab = await FluidCtcVocabulary.load(
    terms: const [FluidVocabularyTerm('FluidAudio'), FluidVocabularyTerm('Kauan')]);
final session = await FluidStreamingAsr.create();
await session.configureVocabulary(vocab); // before start()

// ... or rescore a finished batch transcription against the same vocabulary
final raw = await asr.transcribe(samples);          // must carry tokenTimings
final boosted = await vocab.rescore(raw, samples);  // weight defaults to 10.0
print('${boosted.result.text} applied=${boosted.appliedTerms}');

// Inverse text normalization
final itn = FluidItn();
print(await itn.normalizeSentence('pay twenty five dollars')); // "pay $25"
// ... keeping the word timings attached:
final normalized = await itn.normalizeResult(raw);

// Pre-download / probe / clear any model bundle the library can load
final models = FluidModels();
if (!await models.isDownloaded(ModelKind.diarizer)) {
  await for (final p in models.download(ModelKind.diarizer)) {
    print('${p.phase.name} ${(p.fraction * 100).toStringAsFixed(0)}%');
  }
}

// Text-to-speech
final tts = await FluidKokoroTts.create();
final speech = await tts.synthesizeDetailed('Hello from Flutter.');
// speech.wav is a playable WAV; speech.samples raw 24 kHz PCM

// System audio (macOS 14.4+): transcribe what other apps are playing
final system = FluidSystemAudio();
if (await system.isSupported && await system.requestPermission()) {
  system.health.listen((h) => print('capture: ${h.phase.name}'));
  await system.start(transcribers: [session]);
}

// Record a capture to WAV while it feeds live sessions (pure sink — the
// 16 kHz mono ASR pipeline, written natively; finalized on stop()):
await FluidMicrophone().start(
  transcribers: [session],
  recordToWavPath: '/tmp/meeting_mic.wav',
);
```

## Requirements

- macOS 14+ / iOS 17+ (Qwen3 models require macOS 15+ / iOS 18+)
- Apple Silicon (FluidAudio's CoreML models are arm64-only; no ASR on Intel Macs)
- Flutter 3.44+ (Swift Package Manager integration)

Models are downloaded automatically from HuggingFace
(`FluidInference/*`) on first use and cached under
`~/Library/Application Support/FluidAudio/Models` — except the TTS backends
(Kokoro, PocketTTS), which upstream caches under `~/.cache/fluidaudio/Models`
on macOS. `FluidModels.cacheDirectory` reports the right one per
`ModelKind`.

## Capture ownership

`FluidMicrophone` and `FluidSystemAudio` are **deprecated since 0.4.0**:
production capture belongs to `package:audio_flutter`, which owns device
selection, permissions, health diagnostics and non-Darwin platforms. They keep
working through 0.x and are removed at 1.0. They remain the only way to fan
audio into a FluidAudio session *without* crossing the platform channel — the
session-side `feed` APIs are not deprecated, and `audio_flutter` frames can be
fed to them at the cost of one channel hop per buffer.

## Architecture

The Swift side calls FluidAudio's native async/actor API directly — no C shim,
no FFI. [pigeon](https://pub.dev/packages/pigeon) generates the type-safe
channel layer; event channels stream transcription updates, VAD events, and
download progress back to Dart. Audio crosses the channel as 16 kHz mono
float32 (`Float32List` in Dart).

See `doc/ARCHITECTURE.md` for the full reference (channel conventions,
load-bearing invariants, verification map) and
`doc/design/2026-07-18-fluidaudio-dart-design.md` for the original design.

## Roadmap

- ✅ **M0** — plugin scaffold, shared darwin source (SPM + podspec), pigeon
      round-trip, event channel, typed-data audio convention, CI
- ✅ **M1** — batch ASR (Parakeet v2/v3, token timings), model management with
      download progress, sliding-window streaming ASR, VAD (batch + streaming)
- ✅ **M2** — offline speaker diarization (with embeddings), end-of-utterance
      turn detection
- ✅ **M3** — CTC custom vocabulary boosting, inverse text normalization.
      (Qwen3 multilingual ASR was planned here but the upstream FluidAudio
      0.15.x removed it; it will be bound if it returns upstream.)
- ✅ **M4** — TTS (Kokoro, PocketTTS incl. streaming + voice cloning), audio
      conversion utilities
- ✅ **M5** — native microphone capture (`FluidMicrophone`): AVAudioEngine →
      16 kHz mono → fanned out natively to streaming-ASR / EOU / VAD sessions;
      audio never crosses the platform channel
- ✅ **M6** — system-audio capture (`FluidSystemAudio`, macOS 14.4+): Core
      Audio process taps capture other apps' audio (all, or specific PIDs) —
      the "other participants" track of a meeting transcriber. Requires the
      System Audio Recording permission (`NSAudioCaptureUsageDescription`)
      and an unsandboxed app. *Deprecated in 0.4.0 — see Capture ownership.*
- ✅ **M7** (0.4.0) — model management for every loadable bundle (diarizer,
      CTC-110M, Kokoro, PocketTTS), batch custom-vocabulary rescoring, and
      timing-preserving inverse text normalization

## CocoaPods note

SPM is the primary integration path. If your app still uses CocoaPods, note the
FluidAudio pod on the trunk lags GitHub releases — add this to your Podfile:

```ruby
pod 'FluidAudio', :git => 'https://github.com/FluidInference/FluidAudio.git', :tag => 'v0.15.5'
```

## Development

```sh
flutter pub get
dart run pigeon --input pigeons/fluidaudio.dart   # regenerate channel code
flutter analyze && flutter test                   # fast loop
cd example && flutter test integration_test/plugin_integration_test.dart -d macos  # channel e2e
cd example && FLUIDAUDIO_RUN_MODELS=1 flutter test integration_test/real_models_test.dart -d macos  # real inference
cd example && flutter run -d macos                # demo app
```

## License

The bindings are licensed under the terms in `LICENSE`. FluidAudio itself is
Apache-2.0, © FluidInference.
