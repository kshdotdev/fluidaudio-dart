import 'package:flutter/material.dart';

import 'tabs/diarizer_tab.dart';
import 'tabs/models_tab.dart';
import 'tabs/streaming_tab.dart';
import 'tabs/system_tab.dart';
import 'tabs/transcribe_tab.dart';
import 'tabs/tts_tab.dart';
import 'tabs/vad_tab.dart';

void main() {
  runApp(const FluidAudioExampleApp());
}

class FluidAudioExampleApp extends StatelessWidget {
  const FluidAudioExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fluidaudio_dart example',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      home: const _Home(),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('fluidaudio_dart'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'System'),
              Tab(text: 'Models'),
              Tab(text: 'Transcribe'),
              Tab(text: 'Streaming'),
              Tab(text: 'VAD'),
              Tab(text: 'Diarize'),
              Tab(text: 'TTS'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            SystemTab(),
            ModelsTab(),
            TranscribeTab(),
            StreamingTab(),
            VadTab(),
            DiarizerTab(),
            TtsTab(),
          ],
        ),
      ),
    );
  }
}
