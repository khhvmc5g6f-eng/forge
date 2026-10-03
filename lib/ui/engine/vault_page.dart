import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'actions.dart';
import 'format.dart';
import 'widgets.dart';

/// Provider Vault: providers and the keys under them. Keys appear only by name
/// and the engine's masked display; the secret never comes back from the
/// engine and is never kept after it is sent.
class VaultPage extends ConsumerWidget {
  const VaultPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(engineConnectionProvider);
    final s = conn.state;
    if (s == null) return const _NeedsEngine();
    final addBlocked = actionBlockedReason(conn, 'key.add');
    return PageBody(onRefresh: conn.refresh, children: [
      Row(children: [
        Expanded(child: Text('${s.providers.length} provider(s) · ${s.keys.length} key(s)', style: Theme.of(context).textTheme.titleMedium)),
        Tooltip(
          message: addBlocked ?? 'Add an API key to the engine vault',
          child: FilledButton.icon(
            onPressed: addBlocked != null || s.providers.isEmpty ? null : () => _addKey(context, conn, s),
            icon: const Icon(Icons.add),
            label: const Text('Add key'),
          ),
        ),
      ]),
      if (addBlocked != null) Note(addBlocked, icon: Icons.lock_outline),
      if (conn.isConnected && conn.endpoint != null && !conn.endpoint!.safeForSecrets)
        const Note('This link is unencrypted HTTP to another machine: adding keys is disabled so a secret is never sent in clear text.', icon: Icons.warning_amber_outlined, color: Color(0xFFE0A100)),
      if (s.providers.isEmpty) const Panel(title: 'No providers', child: Note('The engine vault has no providers. Providers are configured on the engine (forge.yaml or the desktop app).')),
      for (final p in s.providers) _ProviderCard(provider: p, keys: s.keysOf(p.id), state: s),
    ]);
  }

  Future<void> _addKey(BuildContext context, EngineConnection conn, EngineState s) async {
    final r = await showDialog<_NewKey>(context: context, builder: (_) => _AddKeyDialog(providers: s.providers, secretsSafe: conn.endpoint?.safeForSecrets ?? false));
    if (r == null || !context.mounted) return;
    await runEngineAction(context, conn, (c) => c.addKey(providerId: r.providerId, name: r.name, secret: r.secret, priority: r.priority), success: 'Key "${r.name}" sent to the engine vault.');
  }
}

class _NeedsEngine extends StatelessWidget {
  const _NeedsEngine();
  @override
  Widget build(BuildContext context) => const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Connect to an engine to see its vault. Nothing is cached on this device.')));
}

class _ProviderCard extends ConsumerWidget {
  const _ProviderCard({required this.provider, required this.keys, required this.state});
  final EngineProvider provider;
  final List<EngineKey> keys;
  final EngineState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(engineConnectionProvider);
    final blocked = actionBlockedReason(conn, 'key.update');
    return Panel(
      title: provider.name,
      subtitle: '${provider.kind.isEmpty ? 'provider' : provider.kind} · ${provider.id}',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(provider.enabled ? 'Enabled' : 'Disabled', style: Theme.of(context).textTheme.bodySmall),
        Tooltip(
          message: blocked ?? 'Enable or disable the whole provider',
          child: Switch(value: provider.enabled, onChanged: blocked != null ? null : (v) => runEngineAction(context, conn, (c) => c.setProviderEnabled(provider.id, v))),
        ),
      ]),
      child: keys.isEmpty
          ? const Note('No keys for this provider.')
          : Column(children: [for (final k in keys) _KeyTile(k: k, conn: conn)]),
    );
  }
}

class _KeyTile extends StatelessWidget {
  const _KeyTile({required this.k, required this.conn});
  final EngineKey k;
  final EngineConnection conn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final upd = actionBlockedReason(conn, 'key.update');
    final test = actionBlockedReason(conn, 'key.test');
    final rm = actionBlockedReason(conn, 'key.remove');
    final cap = k.capacity;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k.name, style: t.titleSmall),
              Text('${k.masked ?? 'masked value not reported'} · priority ${k.priority ?? unknownText}', style: t.bodySmall),
            ]),
          ),
          CircuitPill(k.circuitState),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 14, runSpacing: 4, children: [
          Text('Health ${fmtScore(k.health?.score)}', style: t.bodySmall),
          Text('15 min: ${k.last15m == null ? 'no data' : '${k.last15m!.calls} calls'}', style: t.bodySmall),
          Text('p50 ${fmtMs(k.p50LatencyMs)} · p95 ${fmtMs(k.p95LatencyMs)}', style: t.bodySmall),
        ]),
        if (cap != null && cap.limits.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: CapacityBar(fraction: cap.minRemainingFraction == null ? null : 1 - cap.minRemainingFraction!, status: cap.worst)),
            const SizedBox(width: 8),
            Text(cap.worst, style: t.bodySmall?.copyWith(color: capacityColor(cap.worst))),
          ]),
        ] else
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('No limits configured: capacity unknown', style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor))),
        const SizedBox(height: 4),
        Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Tooltip(message: upd ?? (k.enabled ? 'Disable this key' : 'Enable this key'), child: Switch(value: k.enabled, onChanged: upd != null ? null : (v) => runEngineAction(context, conn, (c) => c.setKeyEnabled(k.id, v)))),
          Text(k.enabled ? 'Enabled' : 'Disabled', style: t.bodySmall),
          const SizedBox(width: 8),
          Tooltip(
            message: test ?? 'Send a real test request with this key',
            child: OutlinedButton.icon(
              onPressed: test != null
                  ? null
                  : () async {
                      final ok = await confirm(context, title: 'Test key "${k.name}"?', message: 'This makes a real request to the provider with this key and may use quota. Results are flagged as tests and excluded from production totals.', action: 'Run test');
                      if (ok && context.mounted) await runEngineAction(context, conn, (c) => c.testKey(k.id));
                    },
              icon: const Icon(Icons.network_check, size: 16),
              label: const Text('Test'),
            ),
          ),
          Tooltip(
            message: upd ?? 'Change priority (lower is preferred)',
            child: OutlinedButton.icon(
              onPressed: upd != null ? null : () => _priority(context),
              icon: const Icon(Icons.low_priority, size: 16),
              label: const Text('Priority'),
            ),
          ),
          Tooltip(
            message: rm ?? 'Remove this key from the vault',
            child: TextButton.icon(
              onPressed: rm != null
                  ? null
                  : () async {
                      final ok = await confirm(context, title: 'Remove key "${k.name}"?', message: 'The key and its stored secret are deleted from the engine vault. This cannot be undone.', action: 'Remove', destructive: true);
                      if (ok && context.mounted) await runEngineAction(context, conn, (c) => c.removeKey(k.id));
                    },
              icon: Icon(Icons.delete_outline, size: 16, color: rm != null ? null : Theme.of(context).colorScheme.error),
              label: const Text('Remove'),
            ),
          ),
        ]),
      ]),
    );
  }

  Future<void> _priority(BuildContext context) async {
    final ctl = TextEditingController(text: '${k.priority ?? 1}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Priority for ${k.name}'),
        content: TextField(controller: ctl, keyboardType: TextInputType.number, decoration: const InputDecoration(helperText: 'Lower number = tried first')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (v != null && context.mounted) await runEngineAction(context, conn, (c) => c.setKeyPriority(k.id, v));
  }
}

class _NewKey {
  const _NewKey(this.providerId, this.name, this.secret, this.priority);
  final String providerId, name, secret;
  final int? priority;
}

class _AddKeyDialog extends StatefulWidget {
  const _AddKeyDialog({required this.providers, required this.secretsSafe});
  final List<EngineProvider> providers;
  final bool secretsSafe;

  @override
  State<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<_AddKeyDialog> {
  late String _provider = widget.providers.first.id;
  final _name = TextEditingController();
  final _secret = TextEditingController();
  final _priority = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    // The secret must not outlive the dialog in memory we control.
    _secret.clear();
    _secret.dispose();
    _name.dispose();
    _priority.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty && _secret.text.trim().isNotEmpty && widget.secretsSafe;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add API key'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<String>(
            initialValue: _provider,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: [for (final p in widget.providers) DropdownMenuItem(value: p.id, child: Text(p.name))],
            onChanged: (v) => setState(() => _provider = v ?? _provider),
          ),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (e.g. work, spare)'), onChanged: (_) => setState(() {})),
          TextField(
            controller: _secret,
            obscureText: !_show,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'API key',
              suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), tooltip: _show ? 'Hide' : 'Show', onPressed: () => setState(() => _show = !_show)),
            ),
            onChanged: (_) => setState(() {}),
          ),
          TextField(controller: _priority, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Priority (optional, lower = first)')),
          const SizedBox(height: 10),
          const Note('The key is sent once to the engine vault and stored there in the OS credential store. It is not kept in this app and is shown only masked afterwards.'),
          if (!widget.secretsSafe) const Padding(padding: EdgeInsets.only(top: 6), child: Note('Disabled: this connection is not encrypted.', icon: Icons.warning_amber_outlined, color: Color(0xFFD64545))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, _NewKey(_provider, _name.text.trim(), _secret.text.trim(), int.tryParse(_priority.text.trim()))) : null,
          child: const Text('Add key'),
        ),
      ],
    );
  }
}
