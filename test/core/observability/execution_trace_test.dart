import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/execution_trace.dart';
import 'package:forge/core/observability/telemetry.dart';

void main() {
  DateTime at(int ms) => DateTime(2026, 1, 1).add(Duration(milliseconds: ms));

  ExecutionTrace buildTrace() {
    final trace = ExecutionTrace();
    trace.addNode(TraceNode(
        id: 's', kind: SpanKind.session, label: 'sess', startedAt: at(0), endedAt: at(1000)));
    trace.addNode(TraceNode(
        id: 'a1', kind: SpanKind.agent, label: 'planning', parentId: 's', startedAt: at(0), endedAt: at(200)));
    trace.addNode(TraceNode(
        id: 'm1', kind: SpanKind.model, label: 'model-x', parentId: 'a1',
        startedAt: at(100), endedAt: at(200), promptTokens: 10, completionTokens: 5, costUsd: 0.01));
    trace.addNode(TraceNode(
        id: 't1', kind: SpanKind.tool, label: 'list_directory', parentId: 'a1', startedAt: at(50), endedAt: at(100)));
    trace.addNode(TraceNode(
        id: 'a2', kind: SpanKind.agent, label: 'coding', parentId: 's', startedAt: at(300), endedAt: at(800)));
    trace.addNode(TraceNode(
        id: 'm2', kind: SpanKind.model, label: 'model-x', parentId: 'a2',
        startedAt: at(400), endedAt: at(800), promptTokens: 100, completionTokens: 50, costUsd: 0.05));
    return trace;
  }

  test('the execution graph preserves real parent/child causality', () {
    final trace = buildTrace();
    expect(trace.roots.map((n) => n.id), ['s']);
    expect(trace.childrenOf('s').map((n) => n.id), unorderedEquals(['a1', 'a2']));
    expect(
        trace.childrenOf('a1').map((n) => n.id), unorderedEquals(['m1', 't1']));
    expect(trace.childrenOf('m2'), isEmpty);
  });

  test('the critical path is the longest-duration root-to-leaf chain', () {
    final path = buildTrace().criticalPath();
    // s(1000ms) -> a2(500ms) -> m2(400ms) = 1900ms beats s->a1->m1 (1300ms).
    expect(path.map((n) => n.id).toList(), ['s', 'a2', 'm2']);
  });

  test('max fan-out exposes delegation width', () {
    expect(buildTrace().maxFanOut(), 2);
  });

  test('breakdownByKind aggregates the per-task time/tokens/cost table', () {
    final rows = buildTrace().breakdownByKind();
    final modelRow = rows.firstWhere((r) => r.label == 'model');
    expect(modelRow.count, 2);
    expect(modelRow.totalDurationMs, 500);
    expect(modelRow.promptTokens, 110);
    expect(modelRow.completionTokens, 55);
    expect(modelRow.costKnown, isTrue);
    expect(modelRow.costUsd, closeTo(0.06, 1e-9));

    final toolRow = rows.firstWhere((r) => r.label == 'tool');
    expect(toolRow.count, 1);
    expect(toolRow.totalDurationMs, 50);
    expect(toolRow.costUsd, 0.0); // tools burn time, not tokens

    // Longest phase first — the "where did the time go" ordering.
    expect(rows.first.label, 'agent');
  });

  test('a node with unknown cost makes its row honestly cost-unknown', () {
    final trace = buildTrace();
    trace.addNode(TraceNode(
        id: 'm3', kind: SpanKind.model, label: 'unknown-pricing', parentId: 's',
        startedAt: at(0), endedAt: at(10), costUsd: null));
    final modelRow =
        trace.breakdownByKind().firstWhere((r) => r.label == 'model');
    expect(modelRow.costKnown, isFalse);
  });

  test('unfinished nodes are excluded from breakdowns', () {
    final trace = buildTrace();
    trace.addNode(TraceNode(
        id: 'a3', kind: SpanKind.agent, label: 'still-running', parentId: 's', startedAt: at(900)));
    final agentRow =
        trace.breakdownByKind().firstWhere((r) => r.label == 'agent');
    expect(agentRow.count, 2); // a1 and a2 only
  });
}
