import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';

class ModelsTab extends StatefulWidget {
  const ModelsTab({super.key});

  @override
  State<ModelsTab> createState() => _ModelsTabState();
}

class _ModelState {
  bool? downloaded;
  double? progress;
  String? phase;
  String? error;
}

class _ModelsTabState extends State<ModelsTab> with AutomaticKeepAliveClientMixin {
  final _models = FluidModels();
  final _state = {for (final kind in ModelKind.values) kind: _ModelState()};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    for (final kind in ModelKind.values) {
      final downloaded = await _models.isDownloaded(kind);
      if (!mounted) return;
      setState(() => _state[kind]!.downloaded = downloaded);
    }
  }

  Future<void> _download(ModelKind kind) async {
    final state = _state[kind]!;
    setState(() {
      state.progress = 0;
      state.error = null;
    });
    try {
      await for (final progress in _models.download(kind)) {
        if (!mounted) return;
        setState(() {
          state.progress = progress.fraction;
          state.phase = progress.phase.name;
        });
      }
      state.progress = null;
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.progress = null;
        state.error = '$error';
      });
    }
  }

  Future<void> _remove(ModelKind kind) async {
    await _models.remove(kind);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final kind in ModelKind.values)
          Card(
            child: ListTile(
              title: Text(kind.name),
              subtitle: _subtitle(kind),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.download),
                    onPressed: _state[kind]!.progress == null ? () => _download(kind) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _remove(kind),
                  ),
                ],
              ),
            ),
          ),
        TextButton(onPressed: _refresh, child: const Text('Refresh status')),
      ],
    );
  }

  Widget _subtitle(ModelKind kind) {
    final state = _state[kind]!;
    if (state.error != null) {
      return Text('error: ${state.error}', style: const TextStyle(color: Colors.red));
    }
    if (state.progress != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: state.progress),
          Text('${state.phase ?? ''} ${(state.progress! * 100).toStringAsFixed(0)}%'),
        ],
      );
    }
    return Text(switch (state.downloaded) {
      true => 'downloaded',
      false => 'not downloaded',
      null => 'checking…',
    });
  }
}
