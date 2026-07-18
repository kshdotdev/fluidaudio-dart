import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

/// Real live dictation: native mic capture fanned out to a streaming-ASR
/// session and a VAD stream (for the level/speech indicator).
class LiveMicTab extends StatefulWidget {
  const LiveMicTab({super.key});

  @override
  State<LiveMicTab> createState() => _LiveMicTabState();
}

class _LiveMicTabState extends State<LiveMicTab> with AutomaticKeepAliveClientMixin {
  final _microphone = FluidMicrophone();

  FluidStreamingAsr? _session;
  FluidVad? _vad;
  FluidVadStream? _vadStream;
  StreamSubscription<FluidTranscriptionUpdate>? _updatesSubscription;
  StreamSubscription<FluidVadStreamEvent>? _vadSubscription;

  String _status = 'idle';
  String _confirmed = '';
  String _volatile = '';
  double _probability = 0;
  bool _busy = false;
  bool _live = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  Future<void> _teardown() async {
    await _microphone.stop();
    await _updatesSubscription?.cancel();
    await _vadSubscription?.cancel();
    await _vadStream?.dispose();
    await _vad?.dispose();
    await _session?.dispose();
    _session = null;
    _vad = null;
    _vadStream = null;
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _status = 'loading models…';
      _confirmed = '';
      _volatile = '';
    });
    try {
      final session = await FluidStreamingAsr.create();
      final vad = await FluidVad.create();
      final vadStream = await vad.stream();

      _updatesSubscription = session.updates.listen((update) {
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
      _vadSubscription = vadStream.events.listen((event) {
        if (mounted) setState(() => _probability = event.probability);
      });

      await session.start();
      await _microphone.start(
        transcribers: [session],
        vadStreams: [vadStream],
      );

      _session = session;
      _vad = vad;
      _vadStream = vadStream;
      setState(() {
        _live = true;
        _status = 'listening — speak!';
      });
    } catch (error) {
      await _teardown();
      setState(() => _status = 'failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _status = 'finishing…';
    });
    try {
      await _microphone.stop();
      final transcript = await _session?.finish();
      setState(() {
        _live = false;
        _status = 'stopped';
        if (transcript != null && transcript.isNotEmpty) {
          _confirmed = transcript;
          _volatile = '';
        }
      });
    } catch (error) {
      setState(() => _status = 'stop failed: $error');
    } finally {
      await _teardown();
      if (mounted) {
        setState(() {
          _busy = false;
          _live = false;
        });
      }
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
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : _live
                        ? _stop
                        : _start,
                icon: Icon(_live ? Icons.stop : Icons.mic),
                label: Text(_live ? 'Stop' : 'Start live dictation'),
              ),
              const SizedBox(width: 16),
              Expanded(child: LinearProgressIndicator(value: _probability)),
            ],
          ),
          const SizedBox(height: 8),
          Text(_status),
          const Divider(height: 24),
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
        ],
      ),
    );
  }
}
