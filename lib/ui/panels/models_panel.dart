import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/local_models/ollama_runtime.dart';
import '../../core/models/providers/nvidia_nim_provider.dart';
import '../../core/models/providers/local_providers.dart';

/// The Models section: the NVIDIA Model Registry table from the brief.
/// "Refresh" performs a real HTTP call to the configured provider's
/// `/v1/models` endpoint — with no API key configured yet this will
/// genuinely fail with an auth error rather than showing fabricated data,
/// which is itself useful signal (see Settings to add a key).
class ModelsPanel extends ConsumerStatefulWidget {
  const ModelsPanel({super.key});

  @override
  ConsumerState<ModelsPanel> createState() => _ModelsPanelState();
}

class _ModelsPanelState extends ConsumerState<ModelsPanel> {
  bool _refreshing = false;
  String? _lastError;
  String? _pullStatus;
  final _pullController = TextEditingController();

  @override
  void dispose() {
    _pullController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(modelRegistryProvider);
    final models = registry.all;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _refreshing ? null : () => _refresh(context),
                  icon: _refreshing
                      ? const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                  label: const Text('Refresh from NVIDIA NIM'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _refreshing ? null : () => _refreshLocal(context),
                  icon: const Icon(Icons.dns_outlined),
                  label: const Text('Refresh local (built-in runtime)'),
                ),
                if (_lastError != null) ...[
                  const SizedBox(width: 12),
                  Expanded(child: Text(_lastError!, style: const TextStyle(color: Colors.red))),
                ],
              ],
            ),
          ),
          _buildRuntimeCard(),
          Expanded(
            child: models.isEmpty
                ? const Center(child: Text('No models registered yet. Click Refresh.'))
                : ListView.builder(
                    itemCount: models.length,
                    itemBuilder: (context, index) {
                      final model = models[index];
                      return ListTile(
                        leading: Icon(
                          model.available ? Icons.check_circle_outline : Icons.error_outline,
                          color: model.available ? Colors.green : Colors.red,
                        ),
                        title: Text(model.id.key),
                        subtitle: Text(
                          'ctx=${model.capabilities.contextWindowTokens} '
                          'tools=${model.capabilities.supportsToolCalling} '
                          'free=${model.capabilities.isFree} '
                          'success=${(model.performance.successRate * 100).toStringAsFixed(0)}% '
                          'runs=${model.performance.totalRuns} '
                          'latency=${model.performance.averageLatencyMs}ms',
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _refresh(BuildContext context) async {
    setState(() {
      _refreshing = true;
      _lastError = null;
    });
    final provider = NvidiaNimProvider(secretsStore: ref.read(secretsStoreProvider));
    try {
      await ref.read(modelRegistryProvider).refreshFromProvider(provider);
    } catch (e) {
      _lastError = 'NVIDIA NIM refresh failed: $e';
    }
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _refreshLocal(BuildContext context) async {
    setState(() {
      _refreshing = true;
      _lastError = null;
    });
    try {
      // The built-in runtime: start Forge's own managed server if needed,
      // then refresh from its endpoint — no separate Ollama installation.
      final runtime = ref.read(ollamaRuntimeProvider);
      await runtime.ensureRunning();
      final provider = OllamaProvider(
        secretsStore: ref.read(secretsStoreProvider),
        baseUrl: runtime.openAiBaseUrl,
      );
      await ref.read(modelRegistryProvider).refreshFromProvider(provider);
    } catch (e) {
      _lastError = 'Built-in local runtime: $e';
    }
    if (mounted) setState(() => _refreshing = false);
  }

  /// The built-in runtime card: live phase, Start/Stop, and a pull field.
  /// The runtime is Forge-owned (`~/.forge/runtime/ollama/`) — see
  /// `lib/core/local_models/ollama_runtime.dart`.
  Widget _buildRuntimeCard() {
    final phase = ref.watch(localRuntimePhaseProvider);
    final running = phase == LocalRuntimePhase.running;
    final busy = phase == LocalRuntimePhase.starting ||
        phase == LocalRuntimePhase.installing;
    final color = switch (phase) {
      LocalRuntimePhase.running => Colors.green,
      LocalRuntimePhase.failed => Colors.red,
      LocalRuntimePhase.starting || LocalRuntimePhase.installing =>
        Colors.orange,
      _ => Colors.grey,
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 6),
              Text('Built-in local runtime — ${phase.name}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (running)
                OutlinedButton(
                  onPressed: () => ref.read(ollamaRuntimeProvider).stop(),
                  child: const Text('Stop'),
                )
              else
                FilledButton.tonal(
                  onPressed: busy ? null : _startRuntime,
                  child: Text(busy ? 'Starting…' : 'Start'),
                ),
            ]),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _pullController,
                  enabled: running,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'model to pull (e.g. qwen2.5-coder:7b)',
                  ),
                  onSubmitted: (_) => _pullModel(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: running ? _pullModel : null,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('Pull'),
              ),
            ]),
            if (_pullStatus != null)
              Text(_pullStatus!,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Future<void> _startRuntime() async {
    setState(() => _lastError = null);
    try {
      await ref.read(ollamaRuntimeProvider).ensureRunning();
    } catch (e) {
      if (mounted) setState(() => _lastError = 'built-in runtime: $e');
    }
  }

  Future<void> _pullModel() async {
    final name = _pullController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _pullStatus = 'pulling $name…';
      _lastError = null;
    });
    try {
      await for (final event
          in ref.read(ollamaRuntimeProvider).pullModel(name)) {
        if (!mounted) return;
        setState(() => _pullStatus = event.progress == null
            ? event.status
            : '${event.status} ${(event.progress! * 100).toStringAsFixed(0)}%');
      }
      if (mounted) setState(() => _pullStatus = 'pulled $name');
    } catch (e) {
      if (mounted) {
        setState(() {
          _pullStatus = null;
          _lastError = 'pull failed: $e';
        });
      }
    }
  }
}
