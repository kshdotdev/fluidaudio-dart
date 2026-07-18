import 'package:flutter_test/flutter_test.dart';

import 'package:fluidaudio_dart_example/main.dart';

void main() {
  testWidgets('app builds with all feature tabs', (tester) async {
    await tester.pumpWidget(const FluidAudioExampleApp());
    await tester.pump();

    for (final tab in ['System', 'Models', 'Transcribe', 'Streaming', 'VAD']) {
      expect(find.text(tab), findsOneWidget);
    }
    // System tab is selected initially; no platform channel in widget tests,
    // so it renders its error/loading path without crashing.
    expect(find.text('Run channel probes'), findsOneWidget);
  });
}
