import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

import '../wav.dart';

class VadTab extends StatefulWidget {
  const VadTab({super.key});

  @override
  State<VadTab> createState() => _VadTabState();
}

class _VadTabState extends State<VadTab> with AutomaticKeepAliveClientMixin {
  String _status = 'idle';
  double _probability = 0;
  final List<String> _events = [];
  bool _running = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _status = 'loading VAD…';
      _events.clear();
      _probability = 0;
    });

    FluidVad? vad;
    FluidVadStream? stream;
    StreamSubscription<FluidVadStreamEvent>? subscription;
    try {
      vad = await FluidVad.create();

      // Batch: speech vs silence sanity check.
      final speech = await loadWavAsset('assets/hello.wav');
      final silence = await loadWavAsset('assets/silence.wav');
      final speechResults = await vad.process(speech);
      final silenceResults = await vad.process(silence);
      final speechActive = speechResults.where((r) => r.isVoiceActive).length;
      final silenceActive = silenceResults.where((r) => r.isVoiceActive).length;

      // Streaming: live probability + segment events.
      stream = await vad.stream();
      subscription = stream.events.listen((event) {
        if (!mounted) return;
        setState(() {
          _probability = event.probability;
          if (event.isSpeechStart) {
            _events.add('speech START at ${event.time?.inMilliseconds ?? '?'} ms');
          } else if (event.isSpeechEnd) {
            _events.add('speech END at ${event.time?.inMilliseconds ?? '?'} ms');
          }
        });
      });
      for (var offset = 0; offset + FluidVadStream.chunkSize <= speech.length;
          offset += FluidVadStream.chunkSize) {
        await stream.feed(Float32List.sublistView(
            speech, offset, offset + FluidVadStream.chunkSize));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      setState(() {
        _status = 'batch: speech $speechActive/${speechResults.length} active chunks, '
            'silence $silenceActive/${silenceResults.length} active chunks';
      });
    } catch (error) {
      setState(() => _status = 'failed: $error');
    } finally {
      await subscription?.cancel();
      await stream?.dispose();
      await vad?.dispose();
      if (mounted) setState(() => _running = false);
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
          FilledButton(
            onPressed: _running ? null : _run,
            child: const Text('Run VAD on fixtures'),
          ),
          const SizedBox(height: 8),
          Text(_status),
          const Divider(height: 24),
          Text('Live probability', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _probability),
          Text(_probability.toStringAsFixed(3)),
          const SizedBox(height: 16),
          Text('Segmentation events (${_events.length}):'),
          Expanded(
            child: ListView(
              children: [for (final line in _events) Text(line)],
            ),
          ),
        ],
      ),
    );
  }
}
