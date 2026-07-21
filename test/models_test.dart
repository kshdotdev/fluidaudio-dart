import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/events.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

class _FakeModelsHostApi implements messages.ModelsHostApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  final List<messages.ModelKindMessage> isDownloadedKinds = [];
  final List<(messages.ModelKindMessage, int)> downloadCalls = [];
  final List<messages.ModelKindMessage> removedKinds = [];
  bool downloadedResult = false;
  bool? offlineMode;
  Object? downloadError;
  Completer<void>? downloadGate;

  @override
  Future<bool> isDownloaded(messages.ModelKindMessage kind) async {
    isDownloadedKinds.add(kind);
    return downloadedResult;
  }

  @override
  Future<void> download(messages.ModelKindMessage kind, int progressToken) async {
    downloadCalls.add((kind, progressToken));
    if (downloadGate != null) await downloadGate!.future;
    final error = downloadError;
    if (error != null) throw error;
  }

  @override
  Future<void> remove(messages.ModelKindMessage kind) async {
    removedKinds.add(kind);
  }

  @override
  Future<String> cacheDirectory(messages.ModelKindMessage kind) async =>
      '/models/${kind.name}';

  @override
  Future<void> setOfflineMode(bool enabled) async {
    offlineMode = enabled;
  }
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('FluidModels', () {
    test('maps every ModelKind to the pigeon enum by index', () async {
      // The bridge in FluidModels maps by index; the two enums must stay in
      // identical order (this pins the newly-added eou case too).
      expect(
        ModelKind.values.map((kind) => kind.name),
        messages.ModelKindMessage.values.map((kind) => kind.name),
      );

      final api = _FakeModelsHostApi();
      final models = FluidModels(hostApi: api, events: FluidEventHub.test());
      for (final kind in ModelKind.values) {
        await models.isDownloaded(kind);
      }
      expect(
        api.isDownloadedKinds.map((kind) => kind.name),
        ModelKind.values.map((kind) => kind.name),
      );
    });

    test('download streams progress for its own token and closes on completion',
        () async {
      final raw = StreamController<messages.DownloadProgressMessage>.broadcast();
      final api = _FakeModelsHostApi()..downloadGate = Completer<void>();
      final models = FluidModels(
        hostApi: api,
        events: FluidEventHub.test(downloadProgress: raw.stream),
      );

      final events = <FluidDownloadProgress>[];
      var done = false;
      models
          .download(ModelKind.eou)
          .listen(events.add, onDone: () => done = true);
      await _pump();

      expect(api.downloadCalls.single, (messages.ModelKindMessage.eou, 1));

      raw.add(messages.DownloadProgressMessage(
        progressToken: 1,
        fraction: 0.5,
        phase: messages.DownloadPhaseMessage.downloading,
      ));
      // Another token's progress must not leak into this stream.
      raw.add(messages.DownloadProgressMessage(
        progressToken: 99,
        fraction: 0.9,
        phase: messages.DownloadPhaseMessage.downloading,
      ));
      await _pump();

      expect(events.map((progress) => progress.fraction), [0.5]);
      expect(done, isFalse);

      // A terminal progress event alone must not close the stream — terminal
      // state is driven by the method-channel result, never by progress.
      raw.add(messages.DownloadProgressMessage(
        progressToken: 1,
        fraction: 1,
        phase: messages.DownloadPhaseMessage.completed,
      ));
      await _pump();
      expect(events.map((progress) => progress.fraction), [0.5, 1.0]);
      expect(done, isFalse);

      api.downloadGate!.complete();
      await _pump();
      expect(done, isTrue);
    });

    test('a cache hit closes the stream with zero progress events', () async {
      final raw = StreamController<messages.DownloadProgressMessage>.broadcast();
      final api = _FakeModelsHostApi();
      final models = FluidModels(
        hostApi: api,
        events: FluidEventHub.test(downloadProgress: raw.stream),
      );

      final events = await models.download(ModelKind.eou).toList();
      expect(events, isEmpty);
    });

    test(
        'a failed download surfaces exactly one typed exception, driven by the '
        'method channel and not by the failed progress event', () async {
      final raw = StreamController<messages.DownloadProgressMessage>.broadcast();
      final api = _FakeModelsHostApi()
        ..downloadGate = Completer<void>()
        ..downloadError =
            PlatformException(code: 'DownloadError', message: 'offline');
      final models = FluidModels(
        hostApi: api,
        events: FluidEventHub.test(downloadProgress: raw.stream),
      );

      final errors = <Object>[];
      var done = false;
      models
          .download(ModelKind.eou)
          .listen((_) {}, onError: errors.add, onDone: () => done = true);
      await _pump();

      // The native side reports failure on the progress channel first; that
      // must neither terminate the stream nor surface an untyped error.
      raw.add(messages.DownloadProgressMessage(
        progressToken: 1,
        fraction: 0.2,
        phase: messages.DownloadPhaseMessage.failed,
        errorMessage: 'offline',
      ));
      await _pump();
      expect(errors, isEmpty);
      expect(done, isFalse);

      api.downloadGate!.complete();
      await _pump();
      expect(errors.single, isA<FluidDownloadException>());
      expect(done, isTrue);
    });

    test('remove, cacheDirectory and setOfflineMode pass through', () async {
      final api = _FakeModelsHostApi();
      final models = FluidModels(hostApi: api, events: FluidEventHub.test());

      await models.remove(ModelKind.eou);
      expect(api.removedKinds, [messages.ModelKindMessage.eou]);

      expect(await models.cacheDirectory(ModelKind.vad), '/models/vad');

      await models.setOfflineMode(true);
      expect(api.offlineMode, isTrue);
    });
  });
}
