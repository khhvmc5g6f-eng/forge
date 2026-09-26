import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/control_plane/capability_router.dart';
import '../../core/control_plane/circuit_breaker.dart';
import '../../core/control_plane/model_tier.dart';

/// Bumping this forces every Control Centre widget watching it to rebuild —
/// `CircuitBreaker`/`TierAssignment` are plain mutable objects (not
/// `StateNotifier`s, since they're written from deep inside the agent
/// runtime, not just from UI actions), so this is the panel's own "refresh"
/// signal rather than true reactive state.
final controlCentreRefreshProvider = StateProvider<int>((ref) => 0);

/// FORGE AI CONTROL CENTRE: live provider/model circuit-breaker state and
/// manual overrides (per the spec's `[Enable] [Disable] [Test] [Configure]
/// [Set Priority]` row), plus Credential Vault management. This is real
/// data from `CircuitBreakerRegistry`/`TierRegistry`/`CredentialVault` — a
/// provider shows CLOSED/healthy until something actually calls it and
/// fails, exactly as the underlying circuit breaker state machine dictates.
class ControlCentrePanel extends ConsumerStatefulWidget {
  const ControlCentrePanel({super.key});

  @override
  ConsumerState<ControlCentrePanel> createState() => _ControlCentrePanelState();
}

class _ControlCentrePanelState extends ConsumerState<ControlCentrePanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() => ref.read(controlCentreRefreshProvider.notifier).state++;

  @override
  Widget build(BuildContext context) {
    ref.watch(controlCentreRefreshProvider);
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Providers & Circuits'), Tab(text: 'Credentials')],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [_ProvidersTab(onChanged: _refresh), _CredentialsTab(onChanged: _refresh)],
          ),
        ),
      ],
    );
  }
}

class _ProvidersTab extends ConsumerWidget {
  const _ProvidersTab({required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(allModelProvidersProvider);
    final circuitBreakers = ref.watch(circuitBreakerRegistryProvider);
    final modelRegistry = ref.watch(modelRegistryProvider);
    final tierRegistry = ref.watch(tierRegistryProvider);

    return ListView(
      padding: const EdgeInsets.all(8),
      children: providers.entries.map((entry) {
        final providerId = entry.key;
        final provider = entry.value;
        final breaker = circuitBreakers.breakerFor(CapabilityRouter.providerCircuitId(providerId));
        final models = modelRegistry.byProvider(providerId);

        return Card(
          child: ExpansionTile(
            leading: _StateDot(state: breaker.state),
            title: Text(providerId),
            subtitle: Text(
              '${breaker.state.name.toUpperCase()} · health ${(breaker.healthScore * 100).toStringAsFixed(0)}% · '
              '${breaker.totalFailures}/${breaker.totalRequests} failed · '
              '429s: ${breaker.total429s} · avg latency ${breaker.averageLatency.inMilliseconds}ms',
            ),
            children: [
              OverflowBar(
                alignment: MainAxisAlignment.start,
                children: [
                  TextButton(
                    onPressed: () async {
                      final started = DateTime.now();
                      try {
                        final ok = await provider.healthCheck();
                        if (ok) {
                          breaker.recordSuccess(latency: DateTime.now().difference(started));
                        } else {
                          breaker.recordFailure(CircuitFailureType.connectionFailure);
                        }
                      } catch (_) {
                        breaker.recordFailure(CircuitFailureType.connectionFailure);
                      }
                      onChanged();
                    },
                    child: const Text('Test'),
                  ),
                  TextButton(onPressed: () { breaker.manualOpen(); onChanged(); }, child: const Text('Open circuit')),
                  TextButton(onPressed: () { breaker.manualClose(); onChanged(); }, child: const Text('Close circuit')),
                  TextButton(
                    onPressed: () { breaker.manualClose(); breaker.resetStatistics(); onChanged(); },
                    child: const Text('Reset'),
                  ),
                ],
              ),
              if (models.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('No models discovered yet — refresh from the Models panel.'),
                )
              else
                ...models.map((model) {
                  final modelBreaker = circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(model.id));
                  final tier = tierRegistry.tierFor(model.id);
                  return ListTile(
                    dense: true,
                    leading: _StateDot(state: modelBreaker.state),
                    title: Text(model.id.modelName),
                    subtitle: Text(
                      '${modelBreaker.state.name} · health ${(modelBreaker.healthScore * 100).toStringAsFixed(0)}% · '
                      'tier: ${tier?.name ?? 'unassigned'}',
                    ),
                    trailing: PopupMenuButton<ModelTier>(
                      tooltip: 'Set tier',
                      onSelected: (t) {
                        tierRegistry.assign(model.id, t, reason: 'manual pin', pin: true);
                        onChanged();
                      },
                      itemBuilder: (context) => ModelTier.values
                          .map((t) => PopupMenuItem(value: t, child: Text('Pin to ${t.name.toUpperCase()}')))
                          .toList(),
                    ),
                  );
                }),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _CredentialsTab extends ConsumerStatefulWidget {
  const _CredentialsTab({required this.onChanged});
  final VoidCallback onChanged;

  @override
  ConsumerState<_CredentialsTab> createState() => _CredentialsTabState();
}

class _CredentialsTabState extends ConsumerState<_CredentialsTab> {
  final _providerController = TextEditingController();
  final _slotController = TextEditingController(text: 'key1');
  final _valueController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(credentialVaultProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Add a credential slot', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _providerController,
                  decoration: const InputDecoration(labelText: 'Provider (e.g. nvidia-nim)', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _slotController,
                  decoration: const InputDecoration(labelText: 'Slot', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _valueController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API key', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () async {
                  if (_providerController.text.trim().isEmpty || _valueController.text.trim().isEmpty) return;
                  await vault.addCredential(
                    _providerController.text.trim(),
                    _slotController.text.trim(),
                    _valueController.text.trim(),
                  );
                  _valueController.clear();
                  widget.onChanged();
                  setState(() {});
                },
                child: const Text('Add'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Configured providers', style: Theme.of(context).textTheme.titleMedium),
          Expanded(
            child: FutureBuilder<List<String>>(
              future: vault.providersConfigured(),
              builder: (context, snapshot) {
                final providers = snapshot.data ?? const [];
                if (providers.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('No credentials configured yet.'),
                  );
                }
                return ListView(
                  children: providers.map((p) => _ProviderCredentialTile(provider: p, vault: vault)).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderCredentialTile extends StatefulWidget {
  const _ProviderCredentialTile({required this.provider, required this.vault});
  final String provider;
  final dynamic vault;

  @override
  State<_ProviderCredentialTile> createState() => _ProviderCredentialTileState();
}

class _ProviderCredentialTileState extends State<_ProviderCredentialTile> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: widget.vault.slotsFor(widget.provider) as Future<List<String>>,
      builder: (context, snapshot) {
        final slots = snapshot.data ?? const [];
        return ExpansionTile(
          leading: const Icon(Icons.vpn_key_outlined),
          title: Text(widget.provider),
          subtitle: Text('${slots.length} slot(s): ${slots.join(', ')}'),
          children: slots
              .map((slot) => ListTile(
                    dense: true,
                    title: Text(slot),
                    trailing: OverflowBar(
                      children: [
                        TextButton(
                          onPressed: () {
                            widget.vault.setActiveSlot(widget.provider, slot);
                            setState(() {});
                          },
                          child: const Text('Set active'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await widget.vault.removeCredential(widget.provider, slot);
                            setState(() {});
                          },
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        );
      },
    );
  }
}

class _StateDot extends StatelessWidget {
  const _StateDot({required this.state});
  final CircuitState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      CircuitState.closed => Colors.green,
      CircuitState.degraded => Colors.orange,
      CircuitState.open => Colors.red,
      CircuitState.halfOpen => Colors.amber,
      CircuitState.recovering => Colors.lightBlue,
    };
    return Icon(Icons.circle, size: 12, color: color);
  }
}
