import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'format.dart';
import 'widgets.dart';

/// One attention item on the dashboard.
class AttentionItem {
  const AttentionItem(this.severity, this.title, this.detail);
  final String severity; // critical | warning | information
  final String title, detail;
}

/// Everything that needs a human, derived only from engine state. Pure and
/// testable. Order: critical first.
List<AttentionItem> attentionItems(EngineState s) {
  final out = <AttentionItem>[];
  for (final n in s.notifications.where((n) => !n.acknowledged && (n.severity == 'critical' || n.severity == 'warning'))) {
    out.add(AttentionItem(n.severity, n.title, n.message));
  }
  for (final k in s.keys) {
    final c = k.circuit;
    if (c != null && c.state != 'closed' && c.state != 'unknown') {
      out.add(AttentionItem(c.state == 'degraded' || c.state == 'half_open' ? 'warning' : 'critical', 'Key ${k.name} circuit ${prettyState(c.state)}',
          c.reason ?? '${c.failuresInWindow} failure(s) in window, ${c.trips} trip(s)'));
    }
    final cap = k.capacity;
    if (cap != null && (cap.worst == 'critical' || cap.worst == 'exhausted')) {
      final worst = cap.limits.where((l) => l.status == cap.worst).map((l) => l.name).join(', ');
      out.add(AttentionItem(cap.worst == 'exhausted' ? 'critical' : 'warning', 'Key ${k.name} capacity ${cap.worst}', worst));
    }
  }
  for (final p in s.providers.where((p) => !p.enabled)) {
    out.add(AttentionItem('information', 'Provider ${p.name} is disabled', 'No traffic is routed to it.'));
  }
  for (final g in s.guard.where((g) => g.needsAttention)) {
    out.add(AttentionItem(g.paused ? 'critical' : 'warning', 'Runaway guard: ${g.scope} at ${prettyState(g.level)}${g.paused ? ' (paused)' : ''}',
        g.signals.isEmpty ? 'No signal detail' : g.signals.last.detail));
  }
  for (final e in s.config.errors) {
    out.add(AttentionItem('warning', 'forge.yaml problem', e));
  }
  for (final i in s.diagnostics.issues) {
    out.add(AttentionItem(i.severity == 'critical' ? 'critical' : 'warning', 'Engine diagnostics: ${prettyState(i.kind)}', i.message));
  }
  if (s.analytics.dropped > 0 || s.analytics.lastError != null) {
    out.add(AttentionItem('warning', 'Analytics store', s.analytics.lastError ?? '${s.analytics.dropped} record(s) dropped'));
  }
  const rank = {'critical': 0, 'warning': 1, 'information': 2};
  out.sort((a, b) => (rank[a.severity] ?? 3).compareTo(rank[b.severity] ?? 3));
  return out;
}

/// Can the engine take a request right now? Verdict derived from key state.
({String verdict, Color color, String detail}) servingVerdict(EngineState s) {
  final enabledProviders = s.providers.where((p) => p.enabled).map((p) => p.id).toSet();
  final candidates = s.keys.where((k) => enabledProviders.contains(k.providerId) || s.providers.isEmpty).toList();
  if (s.keys.isEmpty) return (verdict: 'No keys', color: const Color(0xFFD64545), detail: 'The vault has no API keys, so nothing can be routed.');
  final ok = candidates.where((k) => k.canServe).length;
  if (ok == 0) return (verdict: 'No', color: const Color(0xFFD64545), detail: 'All ${s.keys.length} key(s) are disabled, blocked by a circuit, or out of capacity.');
  if (ok < candidates.length) {
    return (verdict: 'Degraded', color: const Color(0xFFE0A100), detail: '$ok of ${candidates.length} key(s) can serve; the rest are blocked or disabled.');
  }
  return (verdict: 'Yes', color: const Color(0xFF2E9E5B), detail: 'All $ok key(s) can take requests.');
}

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key, this.onOpen});

  /// Navigate to another console page by name (`vault`, `circuits`, `alerts`…).
  final void Function(String page)? onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(engineConnectionProvider);
    final live = ref.watch(engineLiveProvider);
    final s = conn.state;
    if (s == null) return _NoData(conn: conn, onOpen: onOpen);
    final verdict = servingVerdict(s);
    final attention = attentionItems(s);
    final t = Theme.of(context).textTheme;

    return PageBody(onRefresh: conn.refresh, children: [
      AdaptiveGrid(minWidth: 340, children: [
        Panel(
          title: 'Can Forge serve requests right now?',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              StatusPill(verdict.verdict.toUpperCase(), verdict.color),
              const SizedBox(width: 10),
              Text('${s.servableKeys} of ${s.keys.length} keys', style: t.titleMedium),
            ]),
            const SizedBox(height: 8),
            Text(verdict.detail),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in s.providers)
                StatusPill('${p.name}${p.enabled ? '' : ' (off)'}', p.enabled ? const Color(0xFF2E9E5B) : const Color(0xFF7A7F87)),
            ]),
          ]),
        ),
        Panel(
          title: 'What is running now?',
          child: _RunningNow(state: s, live: live),
        ),
        Panel(
          title: 'What needs attention?',
          trailing: attention.isEmpty ? null : StatusPill('${attention.length}', attention.first.severity == 'critical' ? severityColor('critical') : severityColor('warning')),
          child: attention.isEmpty
              ? const Note('Nothing. No open circuits, no capacity warnings, no unacknowledged alerts.', icon: Icons.check_circle_outline, color: Color(0xFF2E9E5B))
              : Column(children: [
                  for (final a in attention.take(8))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(severityIcon(a.severity), color: severityColor(a.severity)),
                      title: Text(a.title),
                      subtitle: Text(a.detail, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                  if (attention.length > 8) Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => onOpen?.call('alerts'), child: Text('and ${attention.length - 8} more'))),
                ]),
        ),
      ]),
      AdaptiveGrid(minWidth: 340, children: [
        Panel(
          title: 'Usage',
          subtitle: 'Production traffic only (key tests are excluded by the engine).',
          child: _UsageSummary(state: s),
        ),
        Panel(
          title: 'Routing',
          subtitle: 'Policy ${s.routing.policy ?? 'unknown'}',
          child: _RoutingSummary(routing: s.routing),
        ),
        Panel(
          title: 'Engine health',
          child: _EngineHealth(state: s, conn: conn),
        ),
      ]),
    ]);
  }
}

class _NoData extends StatelessWidget {
  const _NoData({required this.conn, this.onOpen});
  final EngineConnection conn;
  final void Function(String page)? onOpen;

  @override
  Widget build(BuildContext context) {
    final (title, body) = switch (conn.status) {
      EngineLinkStatus.unconfigured => ('No engine paired', 'Connect to a Forge engine to see providers, keys, circuits, usage and alerts. Nothing is shown until the engine reports it.'),
      EngineLinkStatus.connecting => ('Connecting…', 'Waiting for the first answer from ${conn.endpoint?.label ?? 'the engine'}.'),
      EngineLinkStatus.reconnecting => ('Engine unreachable', '${conn.error ?? ''}\nNo data has been received from this engine in this session, so nothing is shown.'),
      EngineLinkStatus.unauthorized => ('Engine rejected the token', conn.error ?? ''),
      EngineLinkStatus.disconnected => ('Disconnected', 'Reconnect to resume live data.'),
      EngineLinkStatus.connected => ('Waiting for data', 'Connected, but the first state snapshot has not arrived.'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(conn.status == EngineLinkStatus.connecting ? Icons.sync : Icons.cloud_off_outlined, size: 48, color: Theme.of(context).hintColor),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => onOpen?.call('connection'), child: const Text('Open Connection')),
        ]),
      ),
    );
  }
}

class _RunningNow extends StatelessWidget {
  const _RunningNow({required this.state, required this.live});
  final EngineState state;
  final EngineLive live;

  @override
  Widget build(BuildContext context) {
    final active = state.active;
    final tools = live.flow.toolsInFlight;
    if (active.isEmpty && tools.isEmpty) {
      return const Note('Idle. No model calls or tools in flight.');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${active.length} model call(s) · ${tools.length} tool(s)', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      for (final a in active.take(5))
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bolt_outlined),
          title: Text(a.modelId ?? 'model call', overflow: TextOverflow.ellipsis),
          subtitle: Text('${a.keyId ?? '?'} · ${fmtMs(a.ageMs)} · ${a.tokens == null ? '' : '${fmtInt(a.tokens)} tok'}${a.streamTps == null ? '' : ' · ${a.streamTps!.toStringAsFixed(1)} tok/s'}'),
        ),
      for (final t in tools.take(3)) ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(Icons.build_outlined), title: Text(t.tool)),
    ]);
  }
}

class _UsageSummary extends StatelessWidget {
  const _UsageSummary({required this.state});
  final EngineState state;

  @override
  Widget build(BuildContext context) {
    final w = state.totals, all = state.totalsAllTime;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 24, runSpacing: 10, children: [
        Metric(label: 'Calls (15 min)', value: fmtInt(w.calls), sub: w.failureRate == null ? 'no calls' : '${fmtPct(w.failureRate, digits: 1)} failed'),
        Metric(label: 'Tokens (15 min)', value: fmtInt(w.tokens.total), sub: w.estimatedRecords > 0 ? '${w.estimatedRecords} call(s) estimated' : 'provider reported'),
        Metric(label: 'Cost (15 min)', value: fmtCost(w), sub: w.hasCost ? 'from configured prices' : null),
      ]),
      const Divider(height: 24),
      Text('All time: ${fmtInt(all.calls)} calls · ${fmtInt(all.tokens.total)} tokens · ${fmtCost(all)}', style: Theme.of(context).textTheme.bodySmall),
      if (w.avgLatencyMs != null) Text('Average latency ${fmtMs(w.avgLatencyMs)}${w.avgTtftMs == null ? '' : ' · first token ${fmtMs(w.avgTtftMs)}'}', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}

class _RoutingSummary extends StatelessWidget {
  const _RoutingSummary({required this.routing});
  final EngineRouting routing;

  @override
  Widget build(BuildContext context) {
    if (routing.decisions == 0) return const Note('No routing decisions recorded yet.');
    final reasons = routing.rejectionReasons.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 24, runSpacing: 10, children: [
        Metric(label: 'Decisions', value: fmtInt(routing.decisions)),
        Metric(label: 'Used failover', value: fmtInt(routing.failoversUsed), sub: fmtPct(routing.failoversUsed / routing.decisions)),
      ]),
      if (reasons.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('Most common rejections', style: Theme.of(context).textTheme.labelMedium),
        for (final r in reasons.take(3)) Text('${r.value}× ${r.key}', style: Theme.of(context).textTheme.bodySmall),
      ],
    ]);
  }
}

class _EngineHealth extends StatelessWidget {
  const _EngineHealth({required this.state, required this.conn});
  final EngineState state;
  final EngineConnection conn;

  @override
  Widget build(BuildContext context) {
    final d = state.diagnostics;
    final t = Theme.of(context).textTheme.bodySmall;
    final statusColor = switch (d.status) { 'healthy' => const Color(0xFF2E9E5B), 'degraded' => const Color(0xFFE0A100), 'critical' => const Color(0xFFD64545), _ => const Color(0xFF7A7F87) };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, children: [StatusPill((d.status ?? 'no report').toUpperCase(), statusColor)]),
      const SizedBox(height: 6),
      Text('Event stream: ${conn.eventsLive ? 'live' : 'not open'}', style: t),
      Text('Analytics store: ${fmtInt(state.analytics.written)} written, ${state.analytics.dropped} dropped', style: t),
      Text('forge.yaml: ${state.config.present ? (state.config.errors.isEmpty ? 'applied' : '${state.config.errors.length} error(s)') : 'not present'}', style: t),
      if (d.eventLoopLagP99Ms != null) Text('Event loop lag p99: ${d.eventLoopLagP99Ms!.toStringAsFixed(0)} ms', style: t),
      if (d.rssBytes != null) Text('Engine memory: ${(d.rssBytes! / 1048576).toStringAsFixed(0)} MB', style: t),
      if (d.cpuPercent != null) Text('Engine CPU: ${d.cpuPercent!.toStringAsFixed(1)}%', style: t),
    ]);
  }
}
