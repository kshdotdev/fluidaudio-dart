import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

import '../wav.dart';

/// Feeds hello.wav in 100 ms chunks to a streaming session and renders
/// volatile vs confirmed text live — the same shape a live-mic UI would use.
class StreamingTab extends StatefulWidget {
  const StreamingTab({super.key});

  @override
  State<StreamingTab> createState() => _StreamingTabState();
}

class _StreamingTabState extends State<StreamingTab> with AutomaticKeepAliveClientMixin {
  String _status = 'idle';
  String _confirmed = '';
  String _volatile = '';
  String? _finalTranscript;
  bool _running = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _status = 'creating session…';
      _confirmed = '';
      _volatile = '';
      _finalTranscript = null;
    });

    FluidStreamingAsr? session;
    StreamSubscription<FluidTranscriptionUpdate>? subscription;
    try {
      session = await FluidStreamingAsr.create();
      subscription = session.updates.listen((update) {
        if (!mounted) return;
        setState(() {
          if (update.isConfirmed) {
            _confirmed += update.text;
            _volatile = '';
          } else {
            _volatile = update.text;
          }
        });
      });
      await session.start();

      setState(() => _status = 'feeding hello.wav in 100 ms chunks…');
      final samples = await loadWavAsset('assets/hello.wav');
      const chunk = 1600; // 100 ms at 16 kHz
      for (var offset = 0; offset < samples.length; offset += chunk) {
        final end = (offset + chunk).clamp(0, samples.length);
        await session.feed(
            Float32List.sublistView(samples, offset, end));
        // Pace roughly like live audio so partials are visible.
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }

      setState(() => _status = 'finishing…');
      final transcript = await session.finish();
      setState(() {
        _finalTranscript = transcript;
        _status = 'done';
      });
    } catch (error) {
      setState(() => _status = 'failed: $error');
    } finally {
      await subscription?.cancel();
      await session?.dispose();
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
            child: const Text('Stream hello.wav'),
          ),
          const SizedBox(height: 8),
          Text(_status),
          const Divider(height: 24),
          Text('Live transcript', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: _confirmed),
                  TextSpan(
                    text: _volatile,
                    style: TextStyle(color: Theme.of(context).colorScheme.outline),
                  ),
                ]),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
          if (_finalTranscript case final transcript?) ...[
            const Divider(height: 24),
            Text('finish() → "$transcript"'),
          ],
        ],
      ),
    );
  }
}
