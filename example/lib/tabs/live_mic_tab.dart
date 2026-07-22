import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

/// Real live dictation: native mic capture fanned out to a streaming-ASR
/// session and a VAD stream (for the level/speech indicator).
class LiveMicTab extends StatefulWidget {
  const LiveMicTab({super.key});

  @override
  State<LiveMicTab> createState() => _LiveMicTabState();
}

enum _CaptureSource { microphone, systemAudio }

class _LiveMicTabState extends State<LiveMicTab> with AutomaticKeepAliveClientMixin {
  final _microphone = FluidMicrophone();
  final _systemAudio = FluidSystemAudio();

  _CaptureSource _source = _CaptureSource.microphone;
  FluidStreamingAsr? _session;
  FluidVad? _vad;
  FluidVadStream? _vadStream;
  StreamSubscription<FluidTranscriptionUpdate>? _updatesSubscription;
  StreamSubscription<FluidVadStreamEvent>? _vadSubscription;
  StreamSubscription<FluidCaptureHealth>? _healthSubscription;

  String _status = 'idle';
  String _health = '';
  bool _record = false;
  String? _recordedPath;
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
    await _systemAudio.stop();
    await _updatesSubscription?.cancel();
    await _vadSubscription?.cancel();
    await _healthSubscription?.cancel();
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
      _health = '';
      _confirmed = '';
      _volatile = '';
    });
    final wavPath = _record
        ? '${Directory.systemTemp.path}/fluidaudio_'
            '${DateTime.now().millisecondsSinceEpoch}.wav'
        : null;
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
      // Subscribe before starting capture so the validating phase is seen.
      _healthSubscription = (_source == _CaptureSource.systemAudio
              ? _systemAudio.health
              : _microphone.health)
          .listen((event) {
        if (!mounted) return;
        setState(() {
          _health = '${event.phase.name}'
              '${event.detail == null ? '' : ' — ${event.detail}'}';
        });
      });

      if (_source == _CaptureSource.systemAudio) {
        if (!await _systemAudio.isSupported) {
          throw StateError('system-audio capture needs macOS 14.4+');
        }
        if (!await _systemAudio.requestPermission()) {
          throw StateError(
              'System Audio Recording permission missing — grant it in '
              'System Settings > Privacy & Security, then retry');
        }
        await session.start(source: FluidAudioSource.system);
        await _systemAudio.start(
          transcribers: [session],
          vadStreams: [vadStream],
          recordToWavPath: wavPath,
        );
      } else {
        await session.start();
        await _microphone.start(
          transcribers: [session],
          vadStreams: [vadStream],
          recordToWavPath: wavPath,
        );
      }

      _session = session;
      _vad = vad;
      _vadStream = vadStream;
      if (!mounted) return;
      setState(() {
        _live = true;
        _recordedPath = wavPath;
        _status = _source == _CaptureSource.systemAudio
            ? 'capturing system audio — play something!'
            : 'listening — speak!';
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
      await _systemAudio.stop();
      final transcript = await _session?.finish();
      setState(() {
        _live = false;
        _status = _recordedPath == null
            ? 'stopped'
            : 'stopped — WAV: $_recordedPath';
        _health = '';
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
              SegmentedButton<_CaptureSource>(
                segments: const [
                  ButtonSegment(
                      value: _CaptureSource.microphone,
                      icon: Icon(Icons.mic),
                      label: Text('Mic')),
                  ButtonSegment(
                      value: _CaptureSource.systemAudio,
                      icon: Icon(Icons.speaker),
                      label: Text('System')),
                ],
                selected: {_source},
                onSelectionChanged: _live || _busy
                    ? null
                    : (selection) => setState(() => _source = selection.first),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : _live
                        ? _stop
                        : _start,
                icon: Icon(_live ? Icons.stop : Icons.mic),
                label: Text(_live ? 'Stop' : 'Start'),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('Record WAV'),
                selected: _record,
                onSelected: _live || _busy
                    ? null
                    : (selected) => setState(() => _record = selected),
              ),
              const SizedBox(width: 16),
              Expanded(child: LinearProgressIndicator(value: _probability)),
            ],
          ),
          const SizedBox(height: 8),
          Text(_status),
          if (_health.isNotEmpty)
            Text('watchdog: $_health',
                style: Theme.of(context).textTheme.bodySmall),
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
