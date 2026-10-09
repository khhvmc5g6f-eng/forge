/// Neural Observatory — the execution graph and cost attribution.
///
/// Nodes are real spans (session → agent → model request / tool call),
/// edges are actual parent/child causality. The graph answers "where did
/// the time and money go": `breakdownByKind` is the per-task cost table
/// (Planning/Code generation/Tool execution/…), and `criticalPath` is the
/// longest-duration chain through the session.
library;

import 'telemetry.dart';

class TraceNode {
  TraceNode({
    required this.id,
    required this.kind,
    required this.label,
    required this.startedAt,
    this.parentId,
    this.endedAt,
    this.status = SpanStatus.ok,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.costUsd,
    this.errorCount = 0,
  });

  final String id;
  final SpanKind kind;
  final String label;
  final String? parentId;
  final DateTime startedAt;
  DateTime? endedAt;
  SpanStatus status;
  int promptTokens;
  int completionTokens;
  double? costUsd;
  int errorCount;

  Duration get duration =>
      endedAt == null
          ? DateTime.now().difference(startedAt)
          : endedAt!.difference(startedAt);
}

class BreakdownRow {
  const BreakdownRow({
    required this.label,
    required this.count,
    required this.totalDurationMs,
    required this.promptTokens,
    required this.completionTokens,
    required this.costKnown,
    this.costUsd,
  });

  final String label;
  final int count;
  final int totalDurationMs;
  final int promptTokens;
  final int completionTokens;

  /// False when any contributing node had unknown cost — the row shows
  /// tokens/time but no money rather than a partial sum.
  final bool costKnown;
  final double? costUsd;
}

/// The execution graph for one session.
class ExecutionTrace {
  final Map<String, TraceNode> _nodes = {};

  List<TraceNode> get nodes =>
      _nodes.values.toList()..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  TraceNode addNode(TraceNode node) {
    _nodes[node.id] = node;
    return node;
  }

  TraceNode? node(String id) => _nodes[id];

  List<TraceNode> childrenOf(String id) =>
      nodes.where((n) => n.parentId == id).toList();

  List<TraceNode> get roots =>
      nodes.where((n) => n.parentId == null).toList();

  /// Longest-duration root-to-leaf chain — the critical path the replay
  /// view highlights.
  List<TraceNode> criticalPath() {
    if (roots.isEmpty) return const [];
    List<TraceNode> best = const [];
    var bestTotal = 0;

    void walk(TraceNode node, List<TraceNode> path, int total) {
      final kids = childrenOf(node.id);
      final newPath = [...path, node];
      var newTotal = total + node.duration.inMilliseconds;
      if (kids.isEmpty) {
        if (newTotal > bestTotal) {
          bestTotal = newTotal;
          best = newPath;
        }
        return;
      }
      for (final kid in kids) {
        walk(kid, newPath, newTotal);
      }
    }

    for (final root in roots) {
      walk(root, const [], 0);
    }
    return best;
  }

  /// Largest number of direct children any node has — the input to
  /// "excessive agent spawning" detection (compared against the
  /// Orchestrator's SubagentBudget).
  int maxFanOut() {
    final counts = <String, int>{};
    for (final n in nodes) {
      if (n.parentId != null) counts[n.parentId!] = (counts[n.parentId!] ?? 0) + 1;
    }
    return counts.values.fold(0, (a, b) => a > b ? a : b);
  }

  /// Groups finished nodes by span kind into the per-task cost table:
  /// where the time and the money actually went, from real trace data.
  /// Session nodes are excluded — their wall-clock duration *contains*
  /// every phase, so including them would double-count the session's own
  /// time as a "phase".
  List<BreakdownRow> breakdownByKind() {
    final rows = <SpanKind, BreakdownRow>{};
    for (final n in nodes) {
      if (n.endedAt == null || n.kind == SpanKind.session) continue;
      final existing = rows[n.kind];
      rows[n.kind] = BreakdownRow(
        label: n.kind.name,
        count: (existing?.count ?? 0) + 1,
        totalDurationMs: (existing?.totalDurationMs ?? 0) + n.duration.inMilliseconds,
        promptTokens: (existing?.promptTokens ?? 0) + n.promptTokens,
        completionTokens: (existing?.completionTokens ?? 0) + n.completionTokens,
        costKnown: (existing?.costKnown ?? true) && n.costUsd != null,
        costUsd: (existing?.costUsd ?? 0) + (n.costUsd ?? 0),
      );
    }
    return rows.values.toList()..sort((a, b) => b.totalDurationMs.compareTo(a.totalDurationMs));
  }
}
