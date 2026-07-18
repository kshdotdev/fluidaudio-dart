import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

import '../wav.dart';

class DiarizerTab extends StatefulWidget {
  const DiarizerTab({super.key});

  @override
  State<DiarizerTab> createState() => _DiarizerTabState();
}

class _DiarizerTabState extends State<DiarizerTab> with AutomaticKeepAliveClientMixin {
  String _status = 'idle';
  double? _progress;
  FluidDiarizationResult? _result;
  bool _running = false;

  static const _speakerColors = [Colors.teal, Colors.deepOrange, Colors.indigo, Colors.purple];

  @override
  bool get wantKeepAlive => true;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _status = 'loading diarizer…';
      _result = null;
    });

    FluidDiarizer? diarizer;
    try {
      diarizer = await FluidDiarizer.create();
      final progressSubscription = diarizer.progress.listen((event) {
        final (processed, total) = event;
        if (mounted && total > 0) setState(() => _progress = processed / total);
      });

      // Two speakers with a gap of silence between them.
      final first = await loadWavAsset('assets/hello.wav');
      final second = await loadWavAsset('assets/speaker2.wav');
      final samples = Float32List(first.length + 8000 + second.length)
        ..setRange(0, first.length, first)
        ..setRange(first.length + 8000, first.length + 8000 + second.length, second);

      setState(() => _status = 'diarizing ${samples.length ~/ 16000}s of audio…');
      final result = await diarizer.diarize(samples);
      await progressSubscription.cancel();

      setState(() {
        _result = result;
        _status = '${result.speakerIds.length} speakers, '
            '${result.segments.length} segments'
            '${result.timings == null ? '' : ' · ${result.timings!.totalProcessing.inMilliseconds} ms'}';
        _progress = null;
      });
    } catch (error) {
      setState(() {
        _status = 'failed: $error';
        _progress = null;
      });
    } finally {
      await diarizer?.dispose();
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final result = _result;
    final speakers = result?.speakerIds.toList() ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton(
            onPressed: _running ? null : _run,
            child: const Text('Diarize two-speaker fixture'),
          ),
          const SizedBox(height: 8),
          if (_progress != null) LinearProgressIndicator(value: _progress),
          Text(_status),
          const Divider(height: 24),
          if (result != null)
            Expanded(
              child: ListView(
                children: [
                  for (final segment in result.segments)
                    ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 8,
                        backgroundColor: _speakerColors[
                            speakers.indexOf(segment.speakerId) % _speakerColors.length],
                      ),
                      title: Text(
                          '${segment.speakerId}  ${segment.start.inMilliseconds}–${segment.end.inMilliseconds} ms'),
                      subtitle: Text(
                          'quality ${segment.qualityScore.toStringAsFixed(2)} · '
                          'embedding ${segment.embedding.length}d'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
