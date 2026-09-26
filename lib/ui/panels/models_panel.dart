import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
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
                  label: const Text('Refresh local (Ollama)'),
                ),
                if (_lastError != null) ...[
                  const SizedBox(width: 12),
                  Expanded(child: Text(_lastError!, style: const TextStyle(color: Colors.red))),
                ],
              ],
            ),
          ),
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
    final provider = OllamaProvider(secretsStore: ref.read(secretsStoreProvider));
    try {
      await ref.read(modelRegistryProvider).refreshFromProvider(provider);
    } catch (e) {
      _lastError = 'Local Ollama refresh failed (is it running?): $e';
    }
    if (mounted) setState(() => _refreshing = false);
  }
}
