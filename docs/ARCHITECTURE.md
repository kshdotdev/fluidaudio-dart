# fluidaudio_dart — Architecture

Current state of the implementation (see `docs/design/2026-07-18-fluidaudio-dart-design.md`
for the original design and rationale).

## Layers

```
Dart public API          lib/src/*.dart — class-per-domain facades
        │  pigeon @HostApi (@async) + @EventChannelApi
Swift plugin             darwin/fluidaudio_dart/Sources/fluidaudio_dart/
        │  native async/await, actors
FluidAudio (SPM)         pinned .upToNextMinor(from: 0.15.5)
```

Single non-federated plugin, `sharedDarwinSource: true` (one Swift tree for
iOS 17+ and macOS 14+). SPM-first; `darwin/fluidaudio_dart.podspec` is the
CocoaPods fallback. `pigeons/fluidaudio.dart` is the single schema; generated
files (`lib/src/messages.g.dart`, `darwin/.../Messages.g.swift`) are committed
and drift-checked in CI.

## Channel conventions

- **Instance ids**: every create/load host call returns an `int` id addressing
  a native object in `InstanceRegistry`; `dispose(id)` releases it. Dart
  classes carry a `Finalizer` backstop that disposes on GC.
- **Audio bytes**: pigeon has no Float32List, so audio crosses the channel as
  little-endian float32 bytes (`Uint8List`); Dart facades expose `Float32List`
  via zero-copy buffer views (`lib/src/audio_bytes.dart`).
- **Events**: one native stream handler per event family
  (`transcriptionUpdates`, `downloadProgress`, `vadEvents`,
  `diarizationProgress`, `eouEvents`, `ttsChunks`, `micFrames`,
  `systemAudioFrames`, `captureHealth`). Payloads carry an instance id /
  caller token; `FluidEventHub` subscribes each channel once, shares it via
  `asBroadcastStream`, and demultiplexes per handle. Sinks are only touched on
  the main thread.
- **Progress tokens**: model download/compile progress is multiplexed on one
  channel by caller-allocated tokens. Terminal state of
  `FluidModels.download` comes from the method-channel result — progress
  events are advisory (they can race the subscription).
- **TTS streaming**: frames are tagged with a per-call token and closed by an
  ordered `isLast` sentinel on the same channel (never by the method reply,
  which races the last frame).
- **Errors**: Swift `LocalizedError.errorDescription` + stable codes →
  typed `FluidAudioException` subclasses.

## Load-bearing invariants

1. **Strict feed order**: streaming audio reaches each FluidAudio actor via a
   per-instance `SerialTaskQueue` — one drain task, one buffer at a time.
   Concurrent `streamAudio` calls reorder decoding.
2. **Fresh decoder state per one-shot**: batch `transcribe` allocates a new
   `TdtDecoderState` every call; reuse collapses output.
3. **`AVAudioPCMBuffer` never crosses a boundary** (non-Sendable): buffers are
   built natively inside serial contexts.
4. **VAD chunks are exactly 4096 samples** (`SampleChunker` accumulates).
5. **Capture format**: everything is resampled natively to 16 kHz mono
   float32. One `PersistentResampler` per capture session (fed with
   `.noDataNow`) so anti-aliasing filter state carries across buffers.
6. **System tap input format comes from `kAudioTapPropertyFormat`** — never
   the aggregate device's nominal rate.
7. **Teardown order** for the tap chain: `AudioDeviceStop` → `ioQueue.sync`
   flush → `DestroyIOProcID` → `DestroyAggregateDevice` → `DestroyProcessTap`.
8. **Plugin lifecycle**: each engine registration owns an independent
   `PluginRuntime` with idempotent teardown — iOS via
   `publish`/`detachFromEngine`, macOS via a registrar-retained instance whose
   `deinit` fires on engine death. Teardown stops captures and releases every
   registry instance.

## Capture

`FluidMicrophone` (AVAudioEngine tap) and `FluidSystemAudio` (Core Audio
process tap, macOS 14.4+, global-except-self or targeted PIDs via
`listAudioProcesses`) fan out natively through a shared `AudioFanout` to
attached streaming-ASR / EOU / VAD sessions — audio never crosses the
platform channel. Both run a ~2 s watchdog self-test surfaced on `health`
streams; the system tap rebuilds once with fresh process translation when
silent (helpers become tappable only after opening audio), fails-and-stops
only when the chain delivers no callbacks, and reports alive-but-quiet as
informational `silent`.

## Verification

- `flutter test` — facade unit tests with fake host APIs (no channels).
- `example/macos/RunnerTests` — Swift tests incl. SerialTaskQueue FIFO order
  and SampleChunker (run via `xcodebuild test`, wired into CI).
- `example/integration_test/plugin_integration_test.dart` — model-free
  channel e2e (CI PR path).
- `example/integration_test/real_models_test.dart` — real CoreML inference
  (gated by `FLUIDAUDIO_RUN_MODELS=1`; nightly lane with cached models).
  Integration files must run one at a time on macOS (consecutive desktop app
  launches flake).
- Capture paths (mic, system tap) need manual smoke tests — the example's
  Live tab exercises both with the watchdog line visible.

## Known limitations

- Qwen3 is not bound (removed upstream in FluidAudio 0.15.x).
- System-audio capture requires an unsandboxed app and the System Audio
  Recording permission (`NSAudioCaptureUsageDescription`); Screen-Recording
  TCC grants key to the binary's cdhash — sign with a stable identity.
- The tap aggregate is not rebuilt on output-device changes (matching the
  reference implementations' known limitation); the watchdog covers the
  startup window only.
- Hot restart does not re-register plugins: a capture started before a hot
  restart keeps running until the app calls `stop()` or the engine dies.
