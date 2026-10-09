import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/forge_providers.dart';
import '../../../core/observability/model_scorecard.dart';
import '../../../core/observability/observatory_queries.dart';
import '../../../core/observability/observatory_service.dart';
import 'observatory_charts.dart';
import 'observatory_panel.dart' show observatoryTickProvider;

/// Models tab: the live comparison table across every model that has
/// actually served traffic, plus the composite Neural Model Efficiency
/// Score with its published methodology. Every cell is accumulated from
/// real request spans — no synthetic benchmarks.
class ModelsTab extends ConsumerWidget {
  const ModelsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(observatoryTickProvider);
    final observatory = ref.watch(observatoryServiceProvider);
    final cards = observatory.scorecards
      ..sort((a, b) => a.key.compareTo(b.key));
    if (cards.isEmpty) {
      return const Center(
        child: Text('No model requests recorded yet. Rows appear as soon '
            'as instrumented traffic flows.'),
      );
    }
    final comparison = observatory.modelComparison();
    final scores = {for (final s in comparison.scores) s.modelKey: s};

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Model intelligence (live, from real requests)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        DataTable(
          columnSpacing: 18,
          columns: const [
            DataColumn(label: Text('model')),
            DataColumn(label: Text('reqs'), numeric: true),
            DataColumn(label: Text('p95 ms'), numeric: true),
            DataColumn(label: Text('tok/s avg'), numeric: true),
            DataColumn(label: Text('errors'), numeric: true),
            DataColumn(label: Text('429s'), numeric: true),
            DataColumn(label: Text('cost'), numeric: true),
            DataColumn(label: Text('efficiency'), numeric: true),
          ],
          rows: [
            for (final card in cards)
              DataRow(cells: [
                DataCell(Text(card.key)),
                DataCell(Text('${card.requests}')),
                DataCell(Text('${card.latencyMs.p95?.round() ?? '—'}')),
                DataCell(Text(
                    card.tokensPerSecond.mean?.toStringAsFixed(1) ?? '—')),
                DataCell(Text('${card.failures}')),
                DataCell(Text('${card.rateLimited}')),
                DataCell(Text(card.costHasUnknown
                    ? '—'
                    : card.costUsd == 0
                        ? 'free'
                        : '\$${card.costUsd?.toStringAsFixed(4)}')),
                DataCell(Text(_efficiencyCell(scores[card.key]))),
              ]),
          ],
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          title: const Text('Efficiency scoring methodology'),
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(comparison.methodology),
            ),
          ],
        ),
      ],
    );
  }

  String _efficiencyCell(EfficiencyScore? score) {
    if (score == null || score.value == null) return '—';
    if (!score.sufficientData) {
      return 'insufficient data (n=${score.sampleSize})';
    }
    return '${(score.value! * 100).toStringAsFixed(0)}%';
  }
}

/// Network & Providers tab: passive byte counts from real provider
/// traffic (labelled as application traffic, never connection speed),
/// plus per-provider circuit and key health from the Control Plane —
/// masked key references only, never credentials.
class NetworkTab extends ConsumerWidget {
  const NetworkTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(observatoryTickProvider);
    final observatory = ref.watch(observatoryServiceProvider);

    final inSeries = observatory.globalNetworkIn.downsampleTo(120)
        .map((s) => s.value)
        .toList();
    final outSeries = observatory.globalNetworkOut.downsampleTo(120)
        .map((s) => s.value)
        .toList();
    final rows = observatory.providerStatusReader?.call() ??
        const <ProviderStatusRow>[];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Network (passive — real application traffic, measured)',
            style: Theme.of(context).textTheme.titleMedium),
        Text(
          'Received: ${(observatory.networkBytesInTotal / 1e6).toStringAsFixed(2)} MB · '
          'Sent: ${(observatory.networkBytesOutTotal / 1e6).toStringAsFixed(2)} MB',
        ),
        const Text(
          'This is Forge-to-provider HTTP traffic, not the total internet '
          'connection — the distinction is deliberate.',
          style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
        ),
        if (inSeries.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Sparkline(values: inSeries, color: Colors.green),
          ),
        if (outSeries.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Sparkline(values: outSeries, color: Colors.orange),
          ),
        const SizedBox(height: 12),
        Text('Provider & key health (masked references — never credentials)',
            style: Theme.of(context).textTheme.titleMedium),
        if (rows.isEmpty)
          const Text('No Control Plane state available yet.')
        else
          DataTable(
            columnSpacing: 18,
            columns: const [
              DataColumn(label: Text('provider')),
              DataColumn(label: Text('key')),
              DataColumn(label: Text('circuit')),
              DataColumn(label: Text('reqs'), numeric: true),
              DataColumn(label: Text('fails'), numeric: true),
              DataColumn(label: Text('429s'), numeric: true),
              DataColumn(label: Text('avg ms'), numeric: true),
            ],
            rows: [
              for (final row in rows)
                DataRow(cells: [
                  DataCell(Text(row.providerId)),
                  DataCell(Text(row.keyRef)),
                  DataCell(Text(
                    row.circuitState,
                    style: TextStyle(
                      color: row.available ? Colors.green : Colors.red,
                      fontWeight: row.available ? null : FontWeight.bold,
                    ),
                  )),
                  DataCell(Text('${row.requests}')),
                  DataCell(Text('${row.failures}')),
                  DataCell(Text('${row.rateLimited}')),
                  DataCell(Text('${row.averageLatencyMs}')),
                ]),
            ],
          ),
      ],
    );
  }
}

