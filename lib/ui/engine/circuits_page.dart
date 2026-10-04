import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'actions.dart';
import 'format.dart';
import 'widgets.dart';

/// A circuit plus where it sits in the provider -> key -> model tree.
class CircuitNode {
  CircuitNode({required this.level, required this.id, required this.label, required this.circuit, this.children = const [], this.providerId, this.keyId, this.modelId});
  final String level, id, label;

  /// Coordinates the engine's circuit action API wants (not the joined `id`).
  final String? providerId, keyId, modelId;

  /// Null when the engine lists no circuit for it (never tripped, so closed).
  final EngineCircuit? circuit;
  final List<CircuitNode> children;
  String get state => circuit?.state ?? 'closed';
}

/// Builds the breaker tree from engine state. The engine lists only circuits
/// that are not closed or have tripped before; keys always carry their own
/// circuit. Circuits that do not belong to a known provider/key are returned
/// under [orphans] rather than dropped.
({List<CircuitNode> tree, List<EngineCircuit> orphans}) buildCircuitTree(EngineState s) {
  final claimed = <String>{};
  EngineCircuit? find(String level, String id) {
    for (final c in s.circuits) {
      if (c.level == level && c.id == id) return c;
    }
    return null;
  }

  final tree = <CircuitNode>[];
  for (final p in s.providers) {
    final pc = find('provider', p.id);
    if (pc != null) claimed.add('provider:${p.id}');
    final keyNodes = <CircuitNode>[];
    for (final k in s.keysOf(p.id)) {
      final kid = '${p.id}/${k.id}';
      final kc = k.circuit ?? find('key', kid);
      claimed.add('key:$kid');
      final models = s.circuits.where((c) => c.level == 'model' && c.id.startsWith('$kid/')).toList();
      for (final m in models) {
        claimed.add('model:${m.id}');
      }
      keyNodes.add(CircuitNode(
        level: 'key',
        id: kid,
        label: k.name,
        circuit: kc,
        providerId: p.id,
        keyId: k.id,
        children: [
          for (final m in models)
            CircuitNode(level: 'model', id: m.id, label: m.id.substring(kid.length + 1), circuit: m, providerId: p.id, keyId: k.id, modelId: m.id.substring(kid.length + 1))
        ],
      ));
    }
    tree.add(CircuitNode(level: 'provider', id: p.id, label: p.name, circuit: pc, providerId: p.id, children: keyNodes));
  }
  final orphans = s.circuits.where((c) => !claimed.contains('${c.level}:${c.id}')).toList();
  return (tree: tree, orphans: orphans);
}

/// A circuit outside the vault tree: coordinates are recovered from its id
/// (`provider`, `provider/key`, `provider/key/model` where the model may contain `/`).
CircuitNode orphanNode(EngineCircuit c) {
  final parts = c.id.split('/');
  return CircuitNode(
    level: c.level,
    id: c.id,
    label: c.id,
    circuit: c,
    providerId: parts.isNotEmpty ? parts[0] : null,
    keyId: parts.length > 1 ? parts[1] : null,
    modelId: parts.length > 2 ? parts.sublist(2).join('/') : null,
  );
}

class CircuitsPage extends ConsumerWidget {
  const CircuitsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(engineConnectionProvider);
    final s = conn.state;
    if (s == null) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Connect to an engine to see its circuit breakers.')));
    final t = buildCircuitTree(s);
    final blocked = actionBlockedReason(conn, 'circuit.action');
    return PageBody(onRefresh: conn.refresh, children: [
      const Note('Three levels: provider, key, model. A circuit the engine does not list is closed and has never tripped. Counters and timers come from the engine\'s clock.'),
      if (blocked != null) Note(blocked, icon: Icons.lock_outline),
      for (final p in t.tree) _CircuitCard(node: p, state: s, conn: conn, blockedReason: blocked),
      if (t.orphans.isNotEmpty)
        Panel(
          title: 'Other circuits',
          subtitle: 'Not tied to a provider or key currently in the vault.',
          child: Column(children: [
            for (final c in t.orphans) _CircuitRow(node: orphanNode(c), state: s, conn: conn, blockedReason: blocked, depth: 0),
          ]),
        ),
    ]);
  }
}

class _CircuitCard extends StatelessWidget {
  const _CircuitCard({required this.node, required this.state, required this.conn, required this.blockedReason});
  final CircuitNode node;
  final EngineState state;
  final EngineConnection conn;
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: node.label,
      subtitle: 'provider circuit',
      trailing: CircuitPill(node.state),
      child: Column(children: [
        _CircuitRow(node: node, state: state, conn: conn, blockedReason: blockedReason, depth: 0, showLabel: false),
        for (final k in node.children) ...[
          const Divider(height: 16),
          _CircuitRow(node: k, state: state, conn: conn, blockedReason: blockedReason, depth: 1),
          for (final m in k.children) _CircuitRow(node: m, state: state, conn: conn, blockedReason: blockedReason, depth: 2),
        ],
        if (node.children.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Note('No keys under this provider.')),
      ]),
    );
  }
}

class _CircuitRow extends StatelessWidget {
  const _CircuitRow({required this.node, required this.state, required this.conn, required this.blockedReason, required this.depth, this.showLabel = true});
  final CircuitNode node;
  final EngineState state;
  final EngineConnection conn;
  final String? blockedReason;
  final int depth;
  final bool showLabel;

  String _detail() {
    final c = node.circuit;
    if (c == null) return 'closed · no failures recorded';
    final parts = <String>[
      if (c.reason != null && c.reason!.isNotEmpty) c.reason!,
      '${c.failuresInWindow} failure(s) in window',
      '${c.trips} trip(s)',
      if (c.lastFailureKind != null) 'last: ${prettyState(c.lastFailureKind!)}',
    ];
    final next = c.nextProbeAt ?? c.openUntil ?? c.cooldownUntil;
    if (next != null && c.state != 'closed') {
      final left = Duration(milliseconds: next - state.now);
      parts.add(left.isNegative ? 'probe due' : 'next probe in ${fmtDuration(left)}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final st = node.state;
    final actions = <(String, String, IconData)>[
      if (st == 'disabled') ('enable', 'Enable', Icons.play_arrow) else ('disable', 'Disable', Icons.block),
      if (const {'open', 'cooldown', 'exhausted', 'half_open'}.contains(st)) ('probe', 'Probe now', Icons.network_ping),
      ('reset', 'Reset', Icons.restart_alt),
    ];
    return Padding(
      padding: EdgeInsets.only(left: depth * 16.0, top: 4, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showLabel)
          Row(children: [
            Icon(switch (node.level) { 'provider' => Icons.cloud_outlined, 'key' => Icons.vpn_key_outlined, _ => Icons.memory_outlined }, size: 16),
            const SizedBox(width: 6),
            Expanded(child: Text('${node.label} (${node.level})', style: t.titleSmall, overflow: TextOverflow.ellipsis)),
            CircuitPill(st),
          ]),
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(_detail(), style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor))),
        Wrap(spacing: 6, children: [
          for (final a in actions)
            Tooltip(
              message: blockedReason ?? '${a.$2} this ${node.level} circuit',
              child: TextButton.icon(
                onPressed: blockedReason != null ? null : () => _run(context, a.$1),
                icon: Icon(a.$3, size: 16),
                label: Text(a.$2),
              ),
            ),
        ]),
      ]),
    );
  }

  Future<void> _run(BuildContext context, String action) async {
    if (action == 'disable') {
      final ok = await confirm(context,
          title: 'Disable ${node.level} circuit "${node.label}"?', message: 'No traffic will be routed through it until you enable it again.', action: 'Disable', destructive: true);
      if (!ok || !context.mounted) return;
    }
    if (action == 'probe') {
      final ok = await confirm(context, title: 'Probe now?', message: 'The engine will send one real request through this circuit to see whether it has recovered.', action: 'Probe');
      if (!ok || !context.mounted) return;
    }
    await runEngineAction(context, conn, (c) => c.circuitAction(level: node.level, providerId: node.providerId ?? '', keyId: node.keyId, modelId: node.modelId, action: action));
  }
}
