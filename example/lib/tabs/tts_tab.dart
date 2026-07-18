import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:path_provider/path_provider.dart';

class TtsTab extends StatefulWidget {
  const TtsTab({super.key});

  @override
  State<TtsTab> createState() => _TtsTabState();
}

class _TtsTabState extends State<TtsTab> with AutomaticKeepAliveClientMixin {
  final _textController = TextEditingController(
    text: 'FluidAudio bindings for Flutter are now speaking.',
  );

  FluidKokoroTts? _tts;
  String _status = 'model not loaded';
  double? _progress;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _textController.dispose();
    _tts?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _status = 'loading Kokoro (downloads on first use)…');
    try {
      _tts = await FluidKokoroTts.create(
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress.fraction);
        },
      );
      setState(() {
        _status = 'Kokoro ready (voice af_heart)';
        _progress = null;
      });
    } catch (error) {
      setState(() {
        _status = 'load failed: $error';
        _progress = null;
      });
    }
  }

  Future<void> _synthesize() async {
    final tts = _tts;
    if (tts == null) return;
    setState(() => _status = 'synthesizing…');
    try {
      final result = await tts.synthesizeDetailed(_textController.text);
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/fluidaudio_tts.wav');
      await file.writeAsBytes(result.wav);
      setState(() {
        _status = 'synthesized ${result.duration.inMilliseconds} ms of audio '
            '(${result.samples.length} samples @ ${result.sampleRate} Hz)\n'
            'saved to ${file.path}';
      });
    } catch (error) {
      setState(() => _status = 'failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _textController,
            decoration: const InputDecoration(labelText: 'Text to speak'),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _tts == null ? _load : null,
                child: const Text('Load Kokoro TTS'),
              ),
              FilledButton.tonal(
                onPressed: _tts == null ? null : _synthesize,
                child: const Text('Synthesize'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_progress != null) LinearProgressIndicator(value: _progress),
          Text(_status),
        ],
      ),
    );
  }
}
