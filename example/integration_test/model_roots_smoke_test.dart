// Smoke test for host-managed model roots against a REAL CoreML bundle that
// was assembled file-by-file (no archive extraction) — the exact layout a
// host app's per-file installer produces.
//
// Opt-in:
//   FLUIDAUDIO_MODELS_ROOT=/path/to/models \
//     flutter test integration_test/model_roots_smoke_test.dart -d macos
//
// The root must contain `parakeet-tdt-0.6b-v3/` (local folder names strip the
// upstream "-coreml" suffix) with the v3 int8 file set (Preprocessor/Encoder/
// Decoder/JointDecisionv3 .mlmodelc directories and parakeet_vocab.json).
// Offline mode is enabled, so a broken layout fails loudly instead of
// re-downloading from HuggingFace.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fluidaudio_dart/fluidaudio_dart.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final modelsRoot = Platform.environment['FLUIDAUDIO_MODELS_ROOT'] ?? '';

  group(
    'host-managed model roots',
    skip: modelsRoot.isEmpty ? 'set FLUIDAUDIO_MODELS_ROOT' : false,
    () {
      final models = FluidModels();

      testWidgets(
        'loads a hand-assembled Parakeet v3 bundle offline and locks the roots',
        (tester) async {
          await models.setModelRoots(FluidModelRoots(modelsRoot: modelsRoot));
          await models.setOfflineMode(true);

          final roots = await models.modelRoots();
          expect(roots.modelsRoot, modelsRoot);

          // The layout check must accept the per-file assembled directory.
          expect(await models.isDownloaded(ModelKind.parakeetV3), isTrue);
          expect(
            await models.cacheDirectory(ModelKind.parakeetV3),
            '$modelsRoot/parakeet-tdt-0.6b-v3',
          );

          // The load itself is the point: CoreML must accept .mlmodelc
          // directories it did not extract, resolved through the override.
          final asr = await FluidAsr.load();
          addTearDown(asr.dispose);

          final silence = Float32List(16000);
          final result = await asr.transcribe(silence);
          expect(result.text.trim(), isEmpty);

          // Mutation after an instance exists must be rejected.
          await expectLater(
            models.setModelRoots(const FluidModelRoots(modelsRoot: '/tmp')),
            throwsA(
              isA<FluidAudioException>()
                  .having((error) => error.code, 'code', 'ModelRootsLocked'),
            ),
          );
        },
      );
    },
  );
}
