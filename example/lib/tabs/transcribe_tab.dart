import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

import '../wav.dart';

class TranscribeTab extends StatefulWidget {
  const TranscribeTab({super.key});

  @override
  State<TranscribeTab> createState() => _TranscribeTabState();
}

class _TranscribeTabState extends State<TranscribeTab> with AutomaticKeepAliveClientMixin {
  FluidAsr? _asr;
  String _status = 'model not loaded';
  double? _loadProgress;
  FluidAsrResult? _result;

  @override
  bool get wantKeepAlive => true;

  Future<void> _loadModel() async {
    setState(() => _status = 'loading Parakeet v3…');
    try {
      _asr = await FluidAsr.load(
        onProgress: (progress) {
          if (mounted) setState(() => _loadProgress = progress.fraction);
        },
      );
      setState(() {
        _status = 'model ready';
        _loadProgress = null;
      });
    } catch (error) {
      setState(() {
        _status = 'load failed: $error';
        _loadProgress = null;
      });
    }
  }

  Future<void> _transcribeSamples() async {
    final asr = _asr;
    if (asr == null) return;
    setState(() => _status = 'transcribing samples…');
    try {
      final samples = await loadWavAsset('assets/hello.wav');
      final result = await asr.transcribe(samples);
      setState(() {
        _result = result;
        _status = 'done (samples path)';
      });
    } catch (error) {
      setState(() => _status = 'failed: $error');
    }
  }

  Future<void> _transcribeFile() async {
    final asr = _asr;
    if (asr == null) return;
    setState(() => _status = 'transcribing file…');
    try {
      final path = await materializeWavAsset('assets/hello.wav');
      final result = await asr.transcribeFile(path);
      setState(() {
        _result = result;
        _status = 'done (file path)';
      });
    } catch (error) {
      setState(() => _status = 'failed: $error');
    }
  }

  @override
  void dispose() {
    _asr?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final result = _result;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _asr == null ? _loadModel : null,
                child: const Text('Load Parakeet v3'),
              ),
              FilledButton.tonal(
                onPressed: _asr == null ? null : _transcribeSamples,
                child: const Text('Transcribe hello.wav (samples)'),
              ),
              FilledButton.tonal(
                onPressed: _asr == null ? null : _transcribeFile,
                child: const Text('Transcribe hello.wav (file)'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loadProgress != null) LinearProgressIndicator(value: _loadProgress),
          Text(_status),
          const Divider(height: 24),
          if (result != null) ...[
            Text('Transcript', style: Theme.of(context).textTheme.titleMedium),
            SelectableText(result.text),
            const SizedBox(height: 8),
            Text('confidence ${result.confidence.toStringAsFixed(3)} · '
                'audio ${result.duration.inMilliseconds} ms · '
                'processing ${result.processingTime.inMilliseconds} ms · '
                '${result.rtfx.toStringAsFixed(1)}x realtime'),
            const SizedBox(height: 8),
            if (result.tokenTimings case final timings?)
              Expanded(
                child: ListView(
                  children: [
                    for (final timing in timings)
                      Text('${timing.start.inMilliseconds}–${timing.end.inMilliseconds} ms  '
                          '"${timing.token}"  (${timing.confidence.toStringAsFixed(2)})'),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
