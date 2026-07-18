# fluidaudio_dart — Design

Date: 2026-07-18 · Status: approved

## Goal

First-of-its-kind Dart/Flutter binding for [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0, Swift/CoreML on-device speech: ASR, VAD, diarization, TTS). Long-term goal: enable a Flutter rebuild of the ectos meeting-copilot app (dual-track live transcription, diarization, dictation). This package is the library layer only.

## Decisions

1. **Platform channels + pigeon.** The Swift plugin calls FluidAudio's real async/actor API natively. No C shim, no dart:ffi, no Rust. (The official `fluidaudio-rs` uses a blocking `@_cdecl` semaphore bridge with no callbacks and lossy errors — we deliberately do better, since pigeon `@async` maps 1:1 onto Swift `async`.)
2. **Full surface, milestone delivery.** API designed up front for batch ASR, streaming ASR, Qwen3, VAD, offline diarization (incl. speaker embeddings), EOU, CTC vocabulary, ITN, TTS, model management, system info, AudioConverter. Shipped M0→M4.
3. **macOS 14+ and iOS 17+**, arm64/ANE only. Qwen3 gated macOS 15+/iOS 18+. No simulator inference.

## Architecture

```
Dart public API (class-per-domain, awesome_stt-style facade/services layering)
        │  pigeon @HostApi (@async) + @EventChannelApi (instanceId-multiplexed)
Swift plugin: InstanceRegistry + HostApi impls + EventEmitters + AudioBridge + ErrorMapping
        │  native async/await, actors
FluidAudio SPM package (.upToNextMinor from 0.15.5)
```

- Single non-federated plugin, `sharedDarwinSource: true` (one `darwin/` Swift source for iOS+macOS). SPM-first; podspec fallback (upstream CocoaPods trunk is stale — use `:git/:tag`).
- **Instance registry**: create/load calls return `int instanceId`; stateless channels address stateful actors by id. `dispose(id)` → native `cleanup()`; `detachFromEngine` disposes all; Dart `Finalizer` backstop.
- **Events**: per-family streams (`streamingUpdates`, `downloadProgress`, `vadEvents`, `eouEvents`, `ttsChunks`, `qwen3Transcript`); every payload carries `instanceId`; Dart demuxes into per-handle Streams. Bounded buffers; drop-oldest applies only to unconfirmed (volatile) transcription updates.
- **Audio**: standardize on 16 kHz mono `Float32List`. App-fed chunks (~100 ms) AND FluidAudio's native capture (`.microphone`; `.system` macOS-only). Batch APIs take file paths so large audio never crosses the channel. `AVAudioPCMBuffer` never crosses the boundary (non-Sendable) — built natively inside the drain task.
- **Correctness rules (from ectos production use)**:
  - Subscribe to `transcriptionUpdates` BEFORE `startStreaming`.
  - Feed streaming audio from ONE serial drain task (`AsyncStream<[Float]>` → single `Task` awaiting `streamAudio` per buffer). Concurrent feeding reorders decoding.
  - Fresh `TdtDecoderState` per one-shot transcribe (state reuse collapses output to "."). Batch = stateless one-shots; streaming session owns persistent state natively.
  - Model downloads always surface progress; never silently block.
- **Errors**: Swift `LocalizedError.errorDescription` + stable per-enum codes → typed Dart `FluidAudioException` hierarchy (`FluidUnavailableException`, `FluidAsrException`, `FluidVadException`, `FluidDiarizerException`, `FluidDownloadException`).

## Public Dart API (summary)

`FluidAudio` (bootstrap: offline mode, cache dir) · `FluidModels` (isDownloaded / download → `Stream<DownloadProgress>` / remove, keyed by `ModelKind`) · `FluidSystemInfo` · `FluidAsr` (batch one-shots, tokenTimings) · `FluidStreamingAsr` (session; `updates: Stream<SlidingWindowTranscriptionUpdate>`) · `FluidEou` (partials/utterances streams) · `FluidQwen3Asr` (+streaming; availability-gated) · `FluidVad` (+`FluidVadStream` events) · `FluidDiarizer` (segments + embeddings) · `FluidCtcVocabulary` · `FluidItn` · `FluidKokoroTts`/`FluidPocketTts` · `FluidAudioConverter`.

Validated against ectos: dual-track live transcription = two `FluidStreamingAsr` instances; the 4-stage batch pipeline (resample → VAD trim → transcribe → diarize → assign speakers) is expressible with all fields ectos's stores need.

## Milestones

- **M0 walking skeleton**: scaffold + FluidAudio SPM dep + pigeon with three risk probes (one `@async` round-trip `SystemInfo.summary()`, one event-channel stream, one `Float32List` echo); example prints system info; iOS builds.
- **M1**: batch ASR, model management + progress, sliding-window streaming, VAD.
- **M2**: offline diarization (embeddings), EOU.
- **M3**: Qwen3, CTC vocabulary, ITN.
- **M4**: TTS (Kokoro/PocketTTS incl. streaming), AudioConverter.

## Verification

Dart unit tests (mocked host APIs — pigeon `dartTestOut` is deprecated); Flutter-free `swift test` for registry/mapping; gated `integration_test/` with real models (`FLUIDAUDIO_RUN_MODELS=1`): hello.wav transcript, statelessness regression, chunked-vs-batch ordering equivalence, VAD silence/tone, diarization smoke, TTS PCM. Fixtures generated license-clean via `say` (commands committed). CI: offline lanes on PR (analyze, tests, pigeon drift check, macOS debug build, iOS --no-codesign); nightly integration lane with cached models.

## References

- `references/fluidaudio-rs` — the Rust bridge (test taxonomy + CI worth mirroring; architecture deliberately not).
- `references/awesome_stt/packages/stt` — Dart layering blueprint.
- FluidAudio source (v0.15.x): consumed via SPM; readable locally in ectos's `.build/checkouts/FluidAudio`.
- ectos (`/Users/kauan/Projects/swift/ectos`) — target app whose FluidAudio usage defines the required surface.
