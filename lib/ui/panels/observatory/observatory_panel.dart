import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/forge_providers.dart';
import '../../../core/observability/anomaly.dart';
import '../../../core/observability/health.dart';
import '../../../core/observability/observatory_queries.dart';
import '../../../core/observability/observatory_service.dart';
import 'observatory_model_views.dart';
import 'observatory_session_views.dart';

/// Bumped by the live ticker (and the Refresh button) so every tab
/// rebuilds from the shared [ObservatoryService]'s current state. The
/// service itself is mutable, not reactive — this tick is the panel's
/// refresh signal, exactly like the Control Centre's pattern.
final observatoryTickProvider = StateProvider<int>((ref) => 0);

/// FORGE NEURAL OBSERVATORY: the dedicated diagnostics workspace. Five
/// tabs over ONE shared telemetry service — Overview (health index,
/// alerts, resources), Sessions (live per-session stats, cost
/// attribution), Models (comparison + efficiency scores), Trace
/// (execution graph + critical path), Network & Providers (passive byte
/// counts, masked key/circuit health).
///
/// Every number rendered here is either measured, provider-reported,
/// calculated or explicitly "unavailable" — the measurement-quality labels
/// the core package attaches travel all the way to this surface.
class ObservatoryPanel extends ConsumerStatefulWidget {
  const ObservatoryPanel({super.key});

  @override
  ConsumerState<ObservatoryPanel> createState() => _ObservatoryPanelState();
}

class _ObservatoryPanelState extends ConsumerState<ObservatoryPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 5, vsync: this);
  Timer? _ticker;

  /// Live sampling is disabled under `flutter test` so widget tests can
  /// settle — the same guard `secretsStoreProvider` uses.
  static final bool liveTickEnabled =
      !Platform.environment.containsKey('FLUTTER_TEST');

  @override
  void initState() {
    super.initState();
    if (liveTickEnabled) {
      _ticker = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    }
  }

  Future<void> _tick() async {
    final sampler = ref.read(resourceSamplerProvider);
    final observatory = ref.read(observatoryServiceProvider);
    await observatory.recordResourceSample(await sampler.sample());
    ref.read(observatoryTickProvider.notifier).state++;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(observatoryTickProvider);
    return Column(
      children: [
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Sessions'),
            Tab(text: 'Models'),
            Tab(text: 'Trace'),
            Tab(text: 'Network & Providers'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: const [
              _OverviewTab(),
              SessionsTab(),
              ModelsTab(),
              TraceTab(),
              NetworkTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final observatory = ref.watch(observatoryServiceProvider);
    final health = observatory.computeHealth();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _HealthCard(health: health),
        const SizedBox(height: 8),
        _AlertsCard(observatory: observatory),
        const SizedBox(height: 8),
        _ResourcesCard(observatory: observatory),
      ],
    );
  }
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({required this.health});

  final HealthIndexReport health;

  @override
  Widget build(BuildContext context) {
    final overall = health.overall;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Forge Health Index',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  overall == null
                      ? 'no data yet'
                      : '${(overall * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Monitoring coverage: ${(health.coverage * 100).toStringAsFixed(0)}% '
              '— unmeasured components are excluded, never counted as healthy.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: overall,
              minHeight: 6,
              backgroundColor: Theme.of(context).dividerColor,
            ),
            const SizedBox(height: 8),
            for (final component in health.components)
              Row(
                children: [
                  SizedBox(width: 220, child: Text(component.component.name)),
                  Expanded(
                    child: Text(
                      component.score == null
                          ? '— no data'
                          : '${(component.score! * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        fontWeight: component.score != null &&
                                component.score! < 0.5
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      component.detail,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AlertsCard extends ConsumerWidget {
  const _AlertsCard({required this.observatory});

  final ObservatoryService observatory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = observatory.alerts.active;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Alerts (${active.length} active)',
                style: Theme.of(context).textTheme.titleMedium),
            if (active.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No open anomalies. Detection is rolling-baseline '
                    '(robust MAD z-score); a flat baseline never invents one.'),
              )
            else
              for (final anomaly in active)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    anomaly.severity == Severity.critical
                        ? Icons.error
                        : anomaly.severity == Severity.high
                            ? Icons.warning
                            : Icons.info_outline,
                    color: anomaly.severity == Severity.critical
                        ? Colors.red
                        : anomaly.severity == Severity.high
                            ? Colors.orange
                            : Colors.blue,
                  ),
                  title: Text(anomaly.metric),
                  subtitle: Text(
                    'value ${anomaly.evidence['value']} vs baseline '
                    '${anomaly.evidence['baselineMedian'] ?? anomaly.evidence['oldMedian']} '
                    '(z=${anomaly.evidence['z']?.toStringAsFixed(1)})',
                  ),
                  trailing: TextButton(
                    onPressed: () {
                      observatory.alerts.acknowledge(anomaly.id);
                      ref.read(observatoryTickProvider.notifier).state++;
                    },
                    child: const Text('Acknowledge'),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _ResourcesCard extends StatelessWidget {
  const _ResourcesCard({required this.observatory});

  final ObservatoryService observatory;

  @override
  Widget build(BuildContext context) {
    final cpu = observatory.globalCpuPercent.last;
    final rss = observatory.globalRssBytes.last;
    final store = observatory.store;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Resources & collection health',
                style: Theme.of(context).textTheme.titleMedium),
            Text('Process CPU (measured via ps): '
                '${cpu == null ? '— no samples yet' : '${cpu.toStringAsFixed(1)}%'}'),
            Text('Process RSS (measured): '
                '${rss == null ? '— no samples yet' : '${(rss / 1e6).toStringAsFixed(0)} MB'}'),
            const Text('GPU: unavailable — no accelerator telemetry source '
                'is wired; never invented.'),
            if (store != null) ...[
              Text('Telemetry store: ${store.pendingCount} queued, '
                  '${store.writeFailures} write failures, '
                  '${store.droppedEvents} dropped (retention/backpressure).'),
            ],
          ],
        ),
      ),
    );
  }
}


