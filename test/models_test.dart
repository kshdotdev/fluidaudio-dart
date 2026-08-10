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

  final List<messages.ModelRootsMessage?> setModelRootsCalls = [];
  Object? setModelRootsError;
  messages.ModelRootsMessage resolvedRoots = messages.ModelRootsMessage(
    modelsRoot: '/default/FluidAudio/Models',
    ttsRoot: '/default/.cache/fluidaudio',
  );

  @override
  Future<void> setModelRoots(messages.ModelRootsMessage? roots) async {
    final error = setModelRootsError;
    if (error != null) throw error;
    setModelRootsCalls.add(roots);
  }

  @override
  Future<messages.ModelRootsMessage> modelRoots() async => resolvedRoots;
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('FluidModels', () {
    test('maps every ModelKind to the pigeon enum by index', () async {
      // The bridge in FluidModels maps by index; the two enums must stay in
      // identical order. `test/model_kind_parity_test.dart` is the dedicated
      // guard for that invariant — this asserts the facade honours it.
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

    test('setModelRoots passes both roots through and null clears them',
        () async {
      final api = _FakeModelsHostApi();
      final models = FluidModels(hostApi: api, events: FluidEventHub.test());

      await models.setModelRoots(
        const FluidModelRoots(modelsRoot: '/host/models', ttsRoot: '/host/tts'),
      );
      await models.setModelRoots(const FluidModelRoots(modelsRoot: '/only'));
      await models.setModelRoots(null);

      expect(api.setModelRootsCalls, hasLength(3));
      expect(api.setModelRootsCalls[0]?.modelsRoot, '/host/models');
      expect(api.setModelRootsCalls[0]?.ttsRoot, '/host/tts');
      expect(api.setModelRootsCalls[1]?.modelsRoot, '/only');
      expect(api.setModelRootsCalls[1]?.ttsRoot, isNull);
      expect(api.setModelRootsCalls[2], isNull);
    });

    test('modelRoots reports the resolved defaults', () async {
      final api = _FakeModelsHostApi();
      final models = FluidModels(hostApi: api, events: FluidEventHub.test());

      expect(
        await models.modelRoots(),
        const FluidModelRoots(
          modelsRoot: '/default/FluidAudio/Models',
          ttsRoot: '/default/.cache/fluidaudio',
        ),
      );
    });

    test('a locked or invalid native root surfaces a typed exception',
        () async {
      final api = _FakeModelsHostApi()
        ..setModelRootsError = PlatformException(
            code: 'ModelRootsLocked',
            message: 'roots cannot change after a model instance was created');
      final models = FluidModels(hostApi: api, events: FluidEventHub.test());

      await expectLater(
        models.setModelRoots(const FluidModelRoots(modelsRoot: '/late')),
        throwsA(
          isA<FluidAudioException>()
              .having((error) => error.code, 'code', 'ModelRootsLocked'),
        ),
      );
    });

    test('remove, cacheDirectory and setOfflineMode pass through', () async {
      final api = _FakeModelsHostApi();
      final models = FluidModels(hostApi: api, events: FluidEventHub.test());

      // Every kind, so an appended case cannot be half-wired.
      for (final kind in ModelKind.values) {
        await models.remove(kind);
        expect(await models.cacheDirectory(kind), '/models/${kind.name}');
      }
      expect(
        api.removedKinds.map((kind) => kind.name),
        ModelKind.values.map((kind) => kind.name),
      );

      await models.setOfflineMode(true);
      expect(api.offlineMode, isTrue);
    });
  });
}
