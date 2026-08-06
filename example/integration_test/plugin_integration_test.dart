// End-to-end tests that exercise the real native plugin (no models needed).
//
// Run with: flutter test integration_test -d macos
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fluidaudio_dart/fluidaudio_dart.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final system = FluidAudioSystem();

  testWidgets('systemInfo returns a real summary', (tester) async {
    final info = await system.info();
    expect(info.summary, isNotEmpty);
    // These are mutually exclusive on any Mac; on iOS both are false.
    expect(info.isAppleSilicon && info.isIntelMac, isFalse);
  });

  testWidgets('float32 buffers round-trip bit-exact', (tester) async {
    final samples = Float32List.fromList(
      List.generate(16000, (i) => (i - 8000) / 8000),
    );
    final echoed = await system.echoFloats(samples);
    expect(echoed, samples);
  });

  testWidgets('native events arrive on the debug event channel', (tester) async {
    final received = <FluidDebugEvent>[];
    final subscription = system.debugEvents().listen(received.add);
    addTearDown(subscription.cancel);

    await system.debugEmitEvents(5);
    // Events hop through the platform thread; give them a beat to arrive.
    await tester.pump(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(received, hasLength(5));
    expect(received.first.sequence, 0);
    expect(received.last.sequence, 4);
    expect(received.first.payload, isNotNull);
    expect(received.first.payload, hasLength(2));
  });

  testWidgets('model roots round-trip, restore, and reject bad paths',
      (tester) async {
    final models = FluidModels();
    final defaults = await models.modelRoots();
    expect(defaults.modelsRoot, isNotEmpty);
    expect(defaults.ttsRoot, isNotEmpty);

    final scratch = await Directory.systemTemp.createTemp('fluid_roots.');
    addTearDown(() => scratch.delete(recursive: true));

    await models.setModelRoots(FluidModelRoots(modelsRoot: scratch.path));
    final overridden = await models.modelRoots();
    expect(overridden.modelsRoot, scratch.path);
    // TTS root keeps its default when not overridden.
    expect(overridden.ttsRoot, defaults.ttsRoot);
    // Local folder names strip the upstream "-coreml" suffix.
    expect(
      await models.cacheDirectory(ModelKind.parakeetV3),
      '${scratch.path}/parakeet-tdt-0.6b-v3',
    );

    // Null restores FluidAudio's own caches.
    await models.setModelRoots(null);
    final restored = await models.modelRoots();
    expect(restored.modelsRoot, defaults.modelsRoot);

    // A path that is not an existing directory is rejected.
    await expectLater(
      models.setModelRoots(
        FluidModelRoots(modelsRoot: '${scratch.path}/does-not-exist'),
      ),
      throwsA(
        isA<FluidAudioException>()
            .having((error) => error.code, 'code', 'ModelRootsInvalid'),
      ),
    );
  });
}
