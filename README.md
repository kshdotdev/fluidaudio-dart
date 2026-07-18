# fluidaudio_dart

Flutter bindings for [FluidAudio](https://github.com/FluidInference/FluidAudio) —
on-device speech-to-text, voice activity detection, speaker diarization and
text-to-speech on Apple platforms, powered by CoreML and the Apple Neural Engine.

> **Status: early development (M0 walking skeleton).** The plugin scaffold,
> pigeon channel bridge, and FluidAudio SPM integration are in place and
> verified end-to-end. The speech APIs land next (see the roadmap below).

## Requirements

- macOS 14+ / iOS 17+ (Qwen3 models require macOS 15+ / iOS 18+)
- Apple Silicon (FluidAudio's CoreML models are arm64-only; no ASR on Intel Macs)
- Flutter 3.44+ (Swift Package Manager integration)

Models are downloaded automatically from HuggingFace
(`FluidInference/*`) on first use and cached under
`~/Library/Application Support/FluidAudio/Models`.

## Architecture

The Swift side calls FluidAudio's native async/actor API directly — no C shim,
no FFI. [pigeon](https://pub.dev/packages/pigeon) generates the type-safe
channel layer; event channels stream transcription updates, VAD events, and
download progress back to Dart. Audio crosses the channel as 16 kHz mono
float32 (`Float32List` in Dart).

See `docs/design/2026-07-18-fluidaudio-dart-design.md` for the full design.

## Roadmap

- [x] **M0** — plugin scaffold, shared darwin source (SPM + podspec), pigeon
      round-trip, event channel, typed-data audio convention, CI
- [ ] **M1** — batch ASR (Parakeet v2/v3, token timings), model management with
      download progress, sliding-window streaming ASR, VAD (batch + streaming)
- [ ] **M2** — offline speaker diarization (with embeddings), end-of-utterance
      turn detection
- [ ] **M3** — Qwen3 multilingual ASR (batch + streaming), CTC custom
      vocabulary, inverse text normalization
- [ ] **M4** — TTS (Kokoro, PocketTTS incl. streaming + voice cloning), audio
      conversion utilities

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
cd example && flutter test integration_test -d macos   # e2e against the real plugin
cd example && flutter run -d macos                # demo app
```

## License

The bindings are licensed under the terms in `LICENSE`. FluidAudio itself is
Apache-2.0, © FluidInference.
