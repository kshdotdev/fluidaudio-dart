# Changelog

## 0.1.0 — 2026-07-19

Initial release: complete Flutter bindings for FluidAudio 0.15.x (on-device
speech on Apple platforms via CoreML / Apple Neural Engine). macOS 14+,
iOS 17+, Apple Silicon.

**Speech-to-text**
- `FluidAsr` — batch transcription (Parakeet TDT v2/v3), token timings,
  stateless one-shot semantics.
- `FluidStreamingAsr` — live sliding-window sessions with volatile/confirmed
  update streams and strict feed ordering.
- `FluidEou` — end-of-utterance turn detection with partial/utterance
  streams.
- `FluidCtcVocabulary` + `configureVocabulary` — domain-term boosting
  (CTC-110M keyword spotter).
- `FluidItn` — inverse text normalization ("twenty five dollars" → "$25"),
  graceful no-op when the native library is unavailable.

**Audio analysis**
- `FluidVad` / `FluidVadStream` — Silero voice-activity detection, batch and
  streaming with probability ticks and speech start/end events.
- `FluidDiarizer` — offline speaker diarization (VBx) with raw speaker
  embeddings, speaker database, chunk embeddings, and per-chunk progress.

**Text-to-speech**
- `FluidKokoroTts` — Kokoro on the Apple Neural Engine (24 kHz).
- `FluidPocketTts` — streaming synthesis (80 ms frames) and voice cloning
  from reference audio.

**Capture**
- `FluidMicrophone` — native AVAudioEngine capture, resampled to 16 kHz mono
  and fanned out natively to attached sessions (audio never crosses the
  platform channel).
- `FluidSystemAudio` (macOS 14.4+) — Core Audio process taps capture other
  applications' audio (all, or targeted PIDs via `listAudioProcesses`),
  with a permission preflight for the System Audio Recording prompt.
- Watchdog health streams on both captures (validating → healthy / silent /
  rebuilding / failed) with a one-shot tap rebuild for late-tappable
  Electron/Chromium helpers.

**Infrastructure**
- `FluidModels` — model download with progress streams, cache inspection,
  offline mode (models pulled from HuggingFace `FluidInference/*` on first
  use).
- `FluidAudioConverter` — file/sample resampling to 16 kHz mono, WAV
  encoding.
- Typed `FluidAudioException` hierarchy carrying real native error messages;
  `Finalizer` backstops releasing native models on GC; per-engine plugin
  lifecycle with teardown on engine detach.

Built as a pigeon platform-channel plugin (shared darwin Swift source, SPM
first with a CocoaPods fallback). Verified end-to-end against real CoreML
models; four adversarial review rounds (25 confirmed findings fixed).

Known limitation: Qwen3 multilingual ASR is not bound (removed upstream in
FluidAudio 0.15.x).
