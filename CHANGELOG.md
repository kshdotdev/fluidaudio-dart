# Changelog

## 0.1.0 (unreleased)

- M2: offline speaker diarization (`FluidDiarizer` — segments with raw
  speaker embeddings, speaker database, chunk embeddings, pipeline timings,
  per-chunk progress stream) and end-of-utterance turn detection (`FluidEou`
  with partial/utterance streams).

- M1: batch ASR (`FluidAsr` — Parakeet v2/v3, token timings, stateless
  one-shots), sliding-window streaming ASR (`FluidStreamingAsr` with
  volatile/confirmed update stream and strict feed ordering), VAD (`FluidVad`
  batch + `FluidVadStream` with probability ticks and speech start/end
  events), model management (`FluidModels` with download progress streams,
  cache inspection, offline mode), typed exception hierarchy.
- M0 walking skeleton: plugin scaffold with shared darwin source (SPM +
  CocoaPods fallback), FluidAudio dependency (`.upToNextMinor` from 0.15.5),
  pigeon channel bridge (`@async` host API + event channel), float32
  audio-buffer convention, system-info API, example app, CI.
