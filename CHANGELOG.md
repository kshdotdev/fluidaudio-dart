# Changelog

## 0.1.0 (unreleased)

- Watchdog review fixes (6 confirmed findings): all system-tap chain
  lifecycle mutations now serialize under a lifecycle lock — a concurrent
  `stop()` during the watchdog rebuild could double-destroy Core Audio
  objects or leak a freshly rebuilt live tap; `SerialTaskQueue.drain()`
  (shutdown-safe) flushes pre-rebuild dispatches before stats reset; mic
  watchdog no longer emits stale health after stop; example resets its
  watchdog line per session; phase-mapping tests cover silent/failed.
  Added `docs/ARCHITECTURE.md` and a weekly upstream-watch workflow that
  opens an issue when FluidAudio releases outside the pinned minor.

- Capture watchdog: `FluidMicrophone.health` / `FluidSystemAudio.health`
  streams report phase transitions after start (validating → healthy /
  silent / rebuilding / failed). The system tap self-tests for ~2 s and
  rebuilds once with fresh process translation when silent (Electron helpers
  become tappable late); a dead chain stops with `failed`, while
  alive-but-quiet stays running with informational `silent`.

- `FluidSystemAudio.listAudioProcesses()`: enumerate Core Audio processes
  (pid, bundle id, is-playing) to pick tap targets by app — no permission
  needed for the metadata. M6 review fixes: capture paths now use one
  persistent resampler per session (filter state carries across buffers —
  no more per-buffer converter rebuilds), out-of-range PIDs are rejected
  instead of trapping.

- M6: system-audio capture (`FluidSystemAudio`, macOS 14.4+) via Core Audio
  process taps — captures other applications' audio (global-except-self or
  targeted PIDs), resampled natively to 16 kHz and fanned out to attached
  sessions like the microphone; permission preflight for the System Audio
  Recording TCC prompt; shared `AudioFanout` between mic and system capture.
  The example's Live tab gains a Mic/System source toggle (example app is now
  unsandboxed, as process taps require).

- Stabilization pass (adversarial multi-agent review, 14 confirmed findings
  fixed): plugin teardown on engine detach/re-registration (stops live mic
  capture, releases all native instances); lock-protected mic running flag;
  iOS audio session deactivated on stop; `FluidModels.download` terminal
  state now driven by the method-channel result (no more hangs on cache
  hits); PocketTTS streaming frames tagged per-call with an ordered
  end-of-stream sentinel (concurrent syntheses no longer interleave, no
  close races); Dart `Finalizer` backstops on all instance classes;
  `FluidVad.stream` no longer accepts the inert `minSpeechDuration`;
  Swift RunnerTests (incl. SerialTaskQueue FIFO and SampleChunker tests)
  and model-free channel e2e tests now run on the CI PR path.

- M5: native microphone capture (`FluidMicrophone`) — AVAudioEngine tap,
  native resample to 16 kHz mono, direct fan-out to attached streaming-ASR /
  EOU / VAD sessions (audio never crosses the platform channel), optional
  frame/level events for UI; example gains a Live Mic dictation tab.

- M4: text-to-speech — `FluidKokoroTts` (ANE, 24 kHz, voice ids like
  `af_heart`) and `FluidPocketTts` (streaming 80 ms frames, voice cloning
  from reference audio); `FluidAudioConverter` (file/sample resampling to
  16 kHz mono, WAV encoding).

- M3: custom-vocabulary boosting (`FluidCtcVocabulary` +
  `FluidStreamingAsr.configureVocabulary` — CTC-110M keyword spotter) and
  inverse text normalization (`FluidItn`, graceful no-op when the native
  NeMo library is unavailable). Qwen3 was dropped from scope: removed
  upstream in FluidAudio 0.15.x.

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
