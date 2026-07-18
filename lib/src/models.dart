import 'dart:async';

import 'package:meta/meta.dart';

import 'events.dart';
import 'exceptions.dart';
import 'messages.g.dart' as messages;
import 'types.dart';

/// Model download, cache and offline management.
///
/// Models are pulled from HuggingFace (`FluidInference/*`) on first use and
/// cached under `~/Library/Application Support/FluidAudio/Models`.
class FluidModels {
  FluidModels({@visibleForTesting messages.ModelsHostApi? hostApi, @visibleForTesting FluidEventHub? events})
      : _hostApi = hostApi ?? messages.ModelsHostApi(),
        _events = events ?? FluidEventHub.instance;

  final messages.ModelsHostApi _hostApi;
  final FluidEventHub _events;

  static messages.ModelKindMessage _kind(ModelKind kind) =>
      messages.ModelKindMessage.values[kind.index];

  Future<bool> isDownloaded(ModelKind kind) =>
      wrapPlatformErrors(() => _hostApi.isDownloaded(_kind(kind)));

  /// Downloads [kind], emitting progress. The stream closes when the download
  /// completes and errors with a typed [FluidAudioException] on failure.
  ///
  /// Terminal state is driven by the method-channel result — never by
  /// progress events, which are advisory and can race the subscription (a
  /// cache hit may emit nothing at all).
  Stream<FluidDownloadProgress> download(ModelKind kind) {
    final token = _events.allocateProgressToken();
    late StreamController<FluidDownloadProgress> controller;
    StreamSubscription<FluidDownloadProgress>? subscription;
    controller = StreamController<FluidDownloadProgress>(
      onListen: () {
        subscription = _events.progressFor(token).listen(
          (progress) {
            if (!controller.isClosed) controller.add(progress);
          },
          onError: (Object _) {
            // Failure is reported through the method-channel result below.
          },
          onDone: () {
            // Advisory only; the method-channel result closes the stream.
          },
        );
        // Fire the native download only once the progress listener is live.
        _hostApi.download(_kind(kind), token).then(
          (_) {
            if (!controller.isClosed) controller.close();
          },
          onError: (Object error) {
            if (!controller.isClosed) {
              try {
                rethrowTyped(error);
              } catch (typed) {
                controller.addError(typed);
              }
              controller.close();
            }
          },
        );
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// Removes [kind]'s cached files from disk.
  Future<void> remove(ModelKind kind) =>
      wrapPlatformErrors(() => _hostApi.remove(_kind(kind)));

  /// The on-disk cache directory for [kind].
  Future<String> cacheDirectory(ModelKind kind) =>
      wrapPlatformErrors(() => _hostApi.cacheDirectory(_kind(kind)));

  /// Process-global offline switch. When enabled, any operation that would
  /// touch the network fails instead. Set before loading any model.
  Future<void> setOfflineMode(bool enabled) =>
      wrapPlatformErrors(() => _hostApi.setOfflineMode(enabled));
}
