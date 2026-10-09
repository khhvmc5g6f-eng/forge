/// Neural Observatory — higher-level queries over [ObservatoryService]:
/// session intelligence comparison, health scoring, model comparison and
/// task cost breakdown. These assemble what the recorded telemetry already
/// holds; they never synthesise data the service did not receive.
library;

import 'execution_trace.dart';
import 'health.dart';
import 'model_scorecard.dart';
import 'observatory_service.dart';

/// One row of a Session Intelligence Comparison — sessions doing
/// equivalent work (same label/task) compared on measured outcomes so
/// model routing can be tuned from evidence, not assumption.
class SessionComparisonRow {
  const SessionComparisonRow({
    required this.sessionId,
    required this.label,
    required this.durationMs,
    required this.requests,
    required this.promptTokens,
    required this.completionTokens,
    required this.costUsd,
    required this.errors,
    required this.toolCalls,
    required this.modelsUsed,
  });

  final String sessionId;
  final String label;
  final int durationMs;
  final int requests;
  final int promptTokens;
  final int completionTokens;

  /// null = cost not computable for this session (unconfigured pricing).
  final double? costUsd;
  final int errors;
  final int toolCalls;
  final List<String> modelsUsed;
}

extension ObservatoryQueries on ObservatoryService {
  /// Compares the given sessions on measured outcomes.
  List<SessionComparisonRow> compareSessions(Iterable<String> sessionIds) {
    final rows = <SessionComparisonRow>[];
    for (final id in sessionIds) {
      final stats = liveSessionStats(id);
      if (stats == null) continue;
      rows.add(SessionComparisonRow(
        sessionId: id,
        label: stats.record.label,
        durationMs: stats.record.duration.inMilliseconds,
        requests: stats.requests,
        promptTokens: stats.promptTokens,
        completionTokens: stats.completionTokens,
        costUsd: stats.costUsd,
        errors: stats.errors,
        toolCalls: stats.toolCalls,
        modelsUsed: stats.modelsUsed,
      ));
    }
    return rows;
  }

  /// Per-task cost attribution: where the time and money went, from real
  /// trace nodes (model requests / tool calls / agents), plus the critical
  /// path through the session.
  ({List<BreakdownRow> rows, List<TraceNode> criticalPath}) taskBreakdown(
      String sessionId) {
    final trace = traceFor(sessionId);
    if (trace == null) return (rows: const [], criticalPath: const []);
    return (rows: trace.breakdownByKind(), criticalPath: trace.criticalPath());
  }

  /// The live model comparison table + composite efficiency scores.
  ModelComparison modelComparison() => ModelComparison.compute(scorecards);

  /// The Forge Health Index over real telemetry. Missing measurements
  /// reduce coverage, never fake a pass.
  HealthIndexReport computeHealth() {
    final components = <ComponentHealth>[];

    final latencyStats = globalLatencyMs.statsOf(const Duration(hours: 1));
    final p95 = latencyStats.p95;
    components.add(p95 == null
        ? const ComponentHealth.unavailable(
            HealthComponent.sessionResponsiveness,
            'No model requests observed in the last hour.',
          )
        : ComponentHealth(
            component: HealthComponent.sessionResponsiveness,
            score: 1 - (p95 / 30000).clamp(0.0, 1.0),
            detail: 'P95 request latency ${p95.round()}ms over the last hour.',
          ));

    final rows = providerStatusReader?.call() ?? const <ProviderStatusRow>[];
    components.add(rows.isEmpty
        ? const ComponentHealth.unavailable(
            HealthComponent.modelAvailability,
            'No Control Plane circuit state wired.',
          )
        : ComponentHealth(
            component: HealthComponent.modelAvailability,
            score: rows.where((r) => r.available).length / rows.length,
            detail:
                '${rows.where((r) => r.available).length}/${rows.length} provider circuits available.',
          ));

    components.add(globalRequests == 0
        ? const ComponentHealth.unavailable(
            HealthComponent.apiReliability,
            'No API requests recorded yet.',
          )
        : ComponentHealth(
            component: HealthComponent.apiReliability,
            score: 1 - (globalFailures / globalRequests).clamp(0.0, 1.0),
            detail: '$globalFailures failures of $globalRequests requests.',
          ));

    components.add(globalAgentsStarted == 0
        ? const ComponentHealth.unavailable(
            HealthComponent.agentExecution,
            'No agent executions recorded yet.',
          )
        : ComponentHealth(
            component: HealthComponent.agentExecution,
            score:
                1 - (globalAgentFailures / globalAgentsStarted).clamp(0.0, 1.0),
            detail:
                '$globalAgentFailures failed of $globalAgentsStarted agents.',
          ));

    components.add(const ComponentHealth.unavailable(
      HealthComponent.networkPerformance,
      'Passive byte counting is wired; connection failure telemetry is not.',
    ));

    final cpuStats = globalCpuPercent.statsOf(const Duration(hours: 1));
    final cpuP95 = cpuStats.p95;
    components.add(cpuP95 == null
        ? const ComponentHealth.unavailable(
            HealthComponent.infrastructure,
            'No resource samples collected yet.',
          )
        : ComponentHealth(
            component: HealthComponent.infrastructure,
            score: 1 - (cpuP95 / 100).clamp(0.0, 1.0),
            detail: 'Process CPU P95 ${cpuP95.toStringAsFixed(1)}%.',
          ));

    final errorRate =
        globalErrors.within(const Duration(hours: 1)).length / 60.0;
    components.add(globalRequests == 0
        ? const ComponentHealth.unavailable(
            HealthComponent.errorFrequency,
            'No requests observed; no error rate computable.',
          )
        : ComponentHealth(
            component: HealthComponent.errorFrequency,
            score: 1 - (errorRate / 6).clamp(0.0, 1.0),
            detail: '${errorRate.toStringAsFixed(2)} errors/min (last hour).',
          ));

    final rssStats = globalRssBytes.statsOf(const Duration(hours: 1));
    final rssMax = rssStats.max;
    components.add(rssMax == null
        ? const ComponentHealth.unavailable(
            HealthComponent.resourcePressure,
            'No memory samples collected yet.',
          )
        : ComponentHealth(
            component: HealthComponent.resourcePressure,
            score: 1 - (rssMax / (8 * 1024 * 1024 * 1024)).clamp(0.0, 1.0),
            detail: 'Peak RSS ${(rssMax / 1e9).toStringAsFixed(2)}GB.',
          ));

    return HealthIndex().compute(components);
  }

}
