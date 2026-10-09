import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/forge_providers.dart';
import '../../../core/observability/execution_trace.dart';
import '../../../core/observability/observatory_queries.dart';
import '../../../core/observability/observatory_service.dart';
import '../../../core/observability/telemetry.dart';
import 'observatory_charts.dart';
import 'observatory_panel.dart' show observatoryTickProvider;

/// Sessions tab: pick a session, see its measured profile — the same
/// [SessionStats] the in-session diagnostics strip renders — plus the
/// per-task "where the time and money went" breakdown from real trace
/// nodes.
class SessionsTab extends ConsumerWidget {
  const SessionsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(observatoryTickProvider);
    final observatory = ref.watch(observatoryServiceProvider);
    final sessions = observatory.sessions;
    if (sessions.isEmpty) {
      return const Center(
        child: Text('No sessions recorded yet. Sessions begin when an '
            'instrumented agent run or request is dispatched.'),
      );
    }
    final selected = sessions.first;
    final stats = observatory.liveSessionStats(selected.id);

    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 700;
      final detail = stats == null
          ? const Center(child: Text('No stats for this session.'))
          : _SessionDetail(observatory: observatory, stats: stats);
      if (narrow) {
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            _SessionPicker(observatory: observatory),
            detail,
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 280, child: _SessionPicker(observatory: observatory)),
          const VerticalDivider(width: 1),
          Expanded(child: detail),
        ],
      );
    });
  }
}

class _SessionPicker extends StatelessWidget {
  const _SessionPicker({required this.observatory});

  final ObservatoryService observatory;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        for (final session in observatory.sessions)
          ListTile(
            dense: true,
            title: Text(session.label),
            subtitle: Text(
              '${session.status} · ${session.duration.inSeconds}s · '
              '${session.startedAt.toIso8601String().substring(11, 19)}',
            ),
          ),
      ],
    );
  }
}

class _SessionDetail extends StatelessWidget {
  const _SessionDetail({required this.observatory, required this.stats});

  final ObservatoryService observatory;
  final SessionStats stats;

  @override
  Widget build(BuildContext context) {
    final breakdown = observatory.taskBreakdown(stats.record.id);
    final latency = stats.latency;
    final small = Theme.of(context).textTheme.bodySmall;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(stats.record.label, style: Theme.of(context).textTheme.titleMedium),
        Text(
          '${stats.record.status} · ${stats.record.duration.inSeconds}s · '
          '${stats.requests} requests · ${stats.agents} agent(s) · '
          '${stats.toolCalls} tool calls · ${stats.errors} errors',
        ),
        const SizedBox(height: 8),
        Text(
          'Tokens: ${stats.promptTokens} in / ${stats.completionTokens} out '
          '(${stats.cachedTokens} cached). Cost: '
          '${stats.costUsd == null ? 'unavailable — unconfigured pricing' : '\$${stats.costUsd!.toStringAsFixed(4)}'}'
          ' (calculated from configured prices).',
        ),
        const SizedBox(height: 12),
        Text('Request latency (measured)', style: small),
        Text(
          'last ${latency.last?.round()} · p50 ${latency.p50?.round()} · '
          'p90 ${latency.p90?.round()} · p95 ${latency.p95?.round()} · '
          'p99 ${latency.p99?.round()} ms · trend ${latency.trend.name}',
        ),
        if (stats.latencyValues.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Sparkline(values: stats.latencyValues),
          ),
        const SizedBox(height: 8),
        Text('Generation speed (whole-request average, calculated)', style: small),
        Text('avg ${stats.tokensPerSecond.mean?.toStringAsFixed(1)} · '
            'peak ${stats.tokensPerSecond.max?.toStringAsFixed(1)} tok/s'),
        const SizedBox(height: 8),
        Text('Tools', style: small),
        Text('${stats.toolCalls} calls · ${stats.toolFailures} failures · '
            'p95 ${stats.toolDuration.p95?.round() ?? '—'} ms'),
        const SizedBox(height: 8),
        Text('Context window', style: small),
        Text(
          stats.contextUtilisation == null
              ? 'No context observations recorded.'
              : 'used ${(stats.contextUtilisation! * 100).toStringAsFixed(0)}% · '
                  'remaining ${stats.contextRemaining} tokens',
        ),
        if (stats.contextPrediction.eta != null)
          Text(
            'Predicted exhaustion in '
            '${stats.contextPrediction.eta!.inMinutes} min '
            '(estimated — ${stats.contextPrediction.confidence.name} confidence; '
            '${stats.contextPrediction.reason})',
            style: small,
          ),
        const SizedBox(height: 12),
        Text('Where the time and money went (real trace nodes)',
            style: Theme.of(context).textTheme.titleSmall),
        if (breakdown.rows.isEmpty)
          const Text('No finished spans in this session yet.')
        else
          DataTable(
            columnSpacing: 18,
            columns: const [
              DataColumn(label: Text('phase')),
              DataColumn(label: Text('count'), numeric: true),
              DataColumn(label: Text('duration'), numeric: true),
              DataColumn(label: Text('tokens'), numeric: true),
              DataColumn(label: Text('cost'), numeric: true),
            ],
            rows: [
              for (final row in breakdown.rows)
                DataRow(cells: [
                  DataCell(Text(row.label)),
                  DataCell(Text('${row.count}')),
                  DataCell(Text('${row.totalDurationMs} ms')),
                  DataCell(Text('${row.promptTokens + row.completionTokens}')),
                  DataCell(Text(row.costKnown
                      ? '\$${(row.costUsd ?? 0).toStringAsFixed(4)}'
                      : '—')),
                ]),
            ],
          ),
        const SizedBox(height: 8),
        Text(
          'Critical path: '
          '${breakdown.criticalPath.map((n) => n.label).join(' → ')}',
          style: small,
        ),
      ],
    );
  }
}

/// Trace tab: the execution graph of the selected session — every agent,
/// model request and tool call as a node, edges from real parent/child
/// causality, the critical path highlighted, delegation fan-out visible.
class TraceTab extends ConsumerWidget {
  const TraceTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(observatoryTickProvider);
    final observatory = ref.watch(observatoryServiceProvider);
    final sessions = observatory.sessions;
    if (sessions.isEmpty) {
      return const Center(child: Text('No sessions recorded yet.'));
    }
    final trace = observatory.traceFor(sessions.first.id);
    if (trace == null || trace.nodes.isEmpty) {
      return const Center(child: Text('No trace nodes for this session.'));
    }
    final criticalIds = <String>{
      for (final node in trace.criticalPath()) node.id,
    };
    final fanOut = trace.maxFanOut();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Execution graph (${trace.nodes.length} nodes, max fan-out $fanOut)',
            style: Theme.of(context).textTheme.titleMedium),
        if (fanOut > 4)
          const Text(
            'Wide delegation observed — compare against the Orchestrator '
            'budget before spawning more.',
            style: TextStyle(color: Colors.orange),
          ),
        const SizedBox(height: 8),
        ..._traceRows(trace, criticalIds,
            Theme.of(context).colorScheme.primary),
      ],
    );
  }

  List<Widget> _traceRows(
      ExecutionTrace trace, Set<String> criticalIds, Color criticalColor) {
    final rows = <Widget>[];

    void visit(TraceNode node, int depth) {
      rows.add(Padding(
        padding: EdgeInsets.only(left: 18.0 * depth),
        child: Row(
          children: [
            Icon(
              switch (node.kind) {
                SpanKind.session => Icons.play_circle_outline,
                SpanKind.agent => Icons.smart_toy_outlined,
                SpanKind.model => Icons.memory_outlined,
                SpanKind.tool => Icons.build_circle_outlined,
                SpanKind.network => Icons.lan_outlined,
                SpanKind.resource => Icons.speed_outlined,
                SpanKind.other => Icons.circle_outlined,
              },
              size: 16,
              color: node.status == SpanStatus.error
                  ? Colors.red
                  : criticalIds.contains(node.id)
                      ? criticalColor
                      : null,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                node.label,
                style: criticalIds.contains(node.id)
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
            ),
            Text('${node.duration.inMilliseconds} ms'),
            if (node.status == SpanStatus.error)
              const Icon(Icons.error_outline, size: 14, color: Colors.red),
          ],
        ),
      ));
      for (final child in trace.childrenOf(node.id)) {
        visit(child, depth + 1);
      }
    }

    for (final root in trace.roots) {
      visit(root, 0);
    }
    return rows;
  }
}


