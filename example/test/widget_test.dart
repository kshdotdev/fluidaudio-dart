import 'package:flutter_test/flutter_test.dart';

import 'package:fluidaudio_dart_example/main.dart';

void main() {
  testWidgets('app builds and shows the system info screen', (tester) async {
    await tester.pumpWidget(const FluidAudioExampleApp());
    await tester.pump();

    // No platform channel in widget tests: the app must render its error path.
    expect(find.text('fluidaudio_dart — M0 walking skeleton'), findsOneWidget);
    expect(find.text('Run channel probes'), findsOneWidget);
  });
}
