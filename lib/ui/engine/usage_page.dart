import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'format.dart';
import 'widgets.dart';

/// Usage and capacity per key, from `/forge/state`. Budgets: the engine does
/// not expose budget rules over HTTP yet, which this page says plainly.
class UsagePage extends ConsumerWidget {
  const UsagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(engineConnectionProvider);
    final s = conn.state;
    if (s == null) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Connect to an engine to see usage.')));
    return PageBody(onRefresh: conn.refresh, children: [
      AdaptiveGrid(minWidth: 340, children: [
        _TotalsPanel(title: 'Last 15 minutes', a: s.totals),
        _TotalsPanel(title: 'All time (this engine\'s history)', a: s.totalsAllTime),
      ]),
      Text('Per key', style: Theme.of(context).textTheme.titleMedium),
      if (s.keys.isEmpty) const Note('No keys in the vault.'),
      for (final k in s.keys) _KeyUsage(k: k, state: s),
      Panel(
        title: 'Budgets',
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Note('Per-key limits above (calls, tokens, cost per minute/day/month) are real capacity limits the engine enforces and reports.'),
          SizedBox(height: 6),
          Note('Budget rules (session / project / task / day hard stops that make the gateway answer HTTP 402) are not part of /forge/state, so they cannot be shown or edited here yet. See docs/ENGINE_API.md.', icon: Icons.lock_outline),
        ]),
      ),
      Panel(
        title: 'Analytics store',
        child: Text('${fmtInt(s.analytics.written)} records written · ${s.analytics.dropped} dropped · ${s.analytics.corruptLines} corrupt line(s) · ${fmtInt(s.analytics.rawBytes)} bytes raw'
            '${s.analytics.lastError == null ? '' : '\nLast error: ${s.analytics.lastError}'}\nHistory queries and JSON/CSV export are not available over HTTP yet.'),
      ),
    ]);
  }
}

class _TotalsPanel extends StatelessWidget {
  const _TotalsPanel({required this.title, required this.a});
  final String title;
  final EngineAggregate a;

  @override
  Widget build(BuildContext context) {
    final tk = a.tokens;
    return Panel(
      title: title,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 24, runSpacing: 10, children: [
          Metric(label: 'Calls', value: fmtInt(a.calls), sub: a.calls == 0 ? null : '${a.failures} failed (${fmtPct(a.failureRate, digits: 1)})'),
          Metric(label: 'Tokens', value: fmtInt(tk.total), sub: 'in ${fmtInt(tk.input)} · out ${fmtInt(tk.output)}'),
          Metric(label: 'Cost', value: fmtCost(a), sub: a.hasCost ? 'configured prices only' : null),
        ]),
        const SizedBox(height: 8),
        if (tk.cachedInput > 0 || tk.reasoning > 0) Text('cached ${fmtInt(tk.cachedInput)} · reasoning ${fmtInt(tk.reasoning)}', style: Theme.of(context).textTheme.bodySmall),
        if (a.estimatedRecords > 0)
          Text('${a.estimatedRecords} call(s) have estimated token counts (not provider reported).', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFFE0A100))),
        if (a.avgLatencyMs != null) Text('avg latency ${fmtMs(a.avgLatencyMs)}${a.avgTtftMs == null ? '' : ' · avg first token ${fmtMs(a.avgTtftMs)}'}', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _KeyUsage extends StatelessWidget {
  const _KeyUsage({required this.k, required this.state});
  final EngineKey k;
  final EngineState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final w = k.last15m;
    final cap = k.capacity;
    final provider = state.providerById(k.providerId)?.name ?? k.providerId;
    return Panel(
      title: '${k.name} · $provider',
      trailing: CircuitPill(k.circuitState),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 22, runSpacing: 6, children: [
          _kv(t, 'Calls 15m', w == null ? 'no data' : '${w.calls}'),
          _kv(t, 'Failed', w == null ? unknownText : '${w.failures}'),
          _kv(t, 'Tokens', w == null ? unknownText : fmtInt(w.tokens.total)),
          _kv(t, 'Cost', w == null ? unknownText : fmtCost(w)),
          _kv(t, 'p50', fmtMs(k.p50LatencyMs)),
          _kv(t, 'p95', fmtMs(k.p95LatencyMs)),
          _kv(t, 'Health', fmtScore(k.health?.score)),
        ]),
        if (k.health != null && k.health!.factors.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Health factors (${k.health!.sampleSize} samples)', style: t.bodySmall),
            children: [
              for (final f in k.health!.factors)
                ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text('${f.name}  ${f.value == null ? 'no data' : fmtPct(f.value)}  (weight ${f.weight})'), subtitle: Text(f.detail)),
            ],
          ),
        const SizedBox(height: 8),
        if (cap == null || cap.limits.isEmpty)
          Text('No limits configured for this key: remaining capacity is unknown.', style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor))
        else ...[
          if (!cap.providerQuotaKnown) Text('Provider quota: Unknown (limits below are user configured or inferred).', style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
          for (final l in cap.limits)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(l.name, style: t.bodySmall)),
                  Text(l.max == null ? '${fmtInt(l.used)} used (no max)' : '${fmtInt(l.used)} / ${fmtInt(l.max)}', style: t.bodySmall),
                ]),
                const SizedBox(height: 2),
                CapacityBar(fraction: l.fraction, status: l.status),
                Text('${l.status} · ${prettyState(l.source)}${l.resetsAt == null ? '' : ' · resets in ${fmtDuration(Duration(milliseconds: l.resetsAt! - state.now))}'}',
                    style: t.labelSmall?.copyWith(color: Theme.of(context).hintColor)),
              ]),
            ),
        ],
      ]),
    );
  }

  Widget _kv(TextTheme t, String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(k, style: t.labelSmall),
        Text(v, style: t.titleSmall),
      ]);
}
