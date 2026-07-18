import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

/// M0 walking-skeleton screen: system info + channel probes.
class SystemTab extends StatefulWidget {
  const SystemTab({super.key});

  @override
  State<SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends State<SystemTab> with AutomaticKeepAliveClientMixin {
  final _system = FluidAudioSystem();

  FluidSystemInfo? _info;
  Object? _error;
  String _echoStatus = 'not run';
  final List<String> _events = [];
  StreamSubscription<FluidDebugEvent>? _eventSubscription;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await _system.info();
      if (!mounted) return;
      setState(() => _info = info);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _runProbes() async {
    final samples = Float32List.fromList(
      List.generate(16000, (i) => (i % 100) / 100),
    );
    final echoed = await _system.echoFloats(samples);
    var identicalContent = echoed.length == samples.length;
    if (identicalContent) {
      for (var i = 0; i < samples.length; i++) {
        if (echoed[i] != samples[i]) {
          identicalContent = false;
          break;
        }
      }
    }

    _events.clear();
    await _eventSubscription?.cancel();
    _eventSubscription = _system.debugEvents().listen((event) {
      setState(() {
        _events.add('#${event.sequence} ${event.message} payload=${event.payload}');
      });
    });
    await _system.debugEmitEvents(5);

    if (!mounted) return;
    setState(() {
      _echoStatus = identicalContent
          ? 'OK — ${echoed.length} samples round-tripped bit-exact'
          : 'FAILED — buffers differ';
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('System info', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_error != null) Text('Error: $_error'),
          if (_info case final info?) ...[
            Text(info.summary),
            Text('Apple Silicon: ${info.isAppleSilicon}'),
            Text('Intel Mac: ${info.isIntelMac}'),
            Text('Qwen3 supported: ${info.qwen3Supported}'),
          ] else if (_error == null)
            const CircularProgressIndicator(),
          const Divider(height: 32),
          FilledButton(
            onPressed: _runProbes,
            child: const Text('Run channel probes'),
          ),
          const SizedBox(height: 8),
          Text('Float32 echo: $_echoStatus'),
          const SizedBox(height: 8),
          Text('Events (${_events.length}):'),
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
