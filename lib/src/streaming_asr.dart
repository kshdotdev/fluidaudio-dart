import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'audio_bytes.dart';
import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'types.dart';

/// Live sliding-window speech-to-text session.
///
/// Subscribe to [updates] (ideally before [start]) to receive volatile and
/// confirmed transcription updates. Feed 16 kHz mono float32 chunks with
/// [feed]; buffers are processed strictly in call order. Call [finish] for the
/// final transcript, then [dispose].
///
/// For dual-track use (mic + system audio), create two sessions.
class FluidStreamingAsr {
  FluidStreamingAsr._(this._hostApi, this._instanceId, this._events);

  final messages.StreamingAsrHostApi _hostApi;
  final int _instanceId;
  final FluidEventHub _events;
  bool _disposed = false;

  /// Loads models (downloading if needed) and creates a session.
  static Future<FluidStreamingAsr> create({
    AsrVersion version = AsrVersion.v3,
    FluidStreamingConfig? config,
    void Function(FluidDownloadProgress progress)? onProgress,
    @visibleForTesting messages.StreamingAsrHostApi? hostApi,
    @visibleForTesting FluidEventHub? events,
  }) async {
    final api = hostApi ?? messages.StreamingAsrHostApi();
    final hub = events ?? FluidEventHub.instance;
    final token = hub.allocateProgressToken();
    final subscription =
        onProgress == null ? null : hub.progressFor(token).listen(onProgress, onError: (_) {});
    try {
      final id = await wrapPlatformErrors(
        () => api.create(
          messages.AsrVersionMessage.values[version.index],
          config == null
              ? null
              : messages.StreamingConfigMessage(
                  chunkSeconds: config.chunkSeconds,
                  hypothesisChunkSeconds: config.hypothesisChunkSeconds,
                  leftContextSeconds: config.leftContextSeconds,
                  rightContextSeconds: config.rightContextSeconds,
                  minContextForConfirmation: config.minContextForConfirmation,
                  confirmationThreshold: config.confirmationThreshold,
                ),
          token,
        ),
      );
      return FluidStreamingAsr._(api, id, hub);
    } finally {
      await subscription?.cancel();
    }
  }

  /// Volatile and confirmed transcription updates for this session.
  Stream<FluidTranscriptionUpdate> get updates => _events.updatesFor(_instanceId);

  /// Begins streaming. [source] tags the session's audio origin.
  Future<void> start({FluidAudioSource source = FluidAudioSource.microphone}) {
    _checkNotDisposed();
    return wrapPlatformErrors(
        () => _hostApi.start(_instanceId, messages.AudioSourceMessage.values[source.index]));
  }

  /// Feeds 16 kHz mono float32 samples (~100 ms chunks work well).
  Future<void> feed(Float32List samples) {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.feed(_instanceId, floatsToBytes(samples)));
  }

  /// Flushes pending audio and returns the final transcript.
  Future<String> finish() {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.finish(_instanceId));
  }

  /// Clears transcripts and decoder state for a fresh start.
  Future<void> reset() {
    _checkNotDisposed();
    return wrapPlatformErrors(() => _hostApi.reset(_instanceId));
  }

  /// Releases the session and its native resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await wrapPlatformErrors(() => _hostApi.dispose(_instanceId));
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('FluidStreamingAsr was disposed');
    }
  }
}
