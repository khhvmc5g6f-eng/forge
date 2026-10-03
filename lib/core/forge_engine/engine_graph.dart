import 'dart:math' as math;

import 'engine_models.dart';
import 'json_util.dart';

enum GraphNodeKind { agent, tool, model, key, provider }

class GraphNode {
  GraphNode({required this.id, required this.kind, required this.label, this.state, this.detail});
  final String id;
  final GraphNodeKind kind;
  String label;

  /// Circuit state for key/provider nodes; null when the engine did not say.
  String? state;
  String? detail;

  /// Normalised layout position in [0,1] x [0,1].
  double x = 0, y = 0;

  /// Last real event that touched this node.
  DateTime? lastEventAt;
}

class GraphEdge {
  GraphEdge(this.from, this.to, {this.structural = false});
  final String from, to;

  /// Known from configuration (provider owns key, key serves model), not from traffic.
  bool structural;

  /// Last time a real event travelled along this edge.
  DateTime? lastPulseAt;
  bool lastPulseFailed = false;
  int pulses = 0;

  String get id => '$from>$to';
}

/// The engine as a graph, for the Neural Lab "Forge network" view.
///
/// Nodes: agents and tools (left, only once an event names them), models, keys,
/// providers. Structure comes from `/forge/state` (vault keys, availability
/// matrix); a pulse on an edge exists only because a real event crossed it.
/// Agents are never invented: traffic with no `agentId` is attributed to a
/// single "Unattributed client" node.
class EngineGraph {
  static const pulseWindow = Duration(milliseconds: 2500);
  static const unattributedAgent = 'agent:unattributed';

  final Map<String, GraphNode> nodes = {};
  final Map<String, GraphEdge> edges = {};
  final Map<String, ({String agent, String model})> _reqRoute = {};
  int revision = 0;

  static String agentId(String? id) => id == null || id.isEmpty ? unattributedAgent : 'agent:$id';
  static String modelNode(String id) => 'model:$id';
  static String keyNode(String id) => 'key:$id';
  static String providerNode(String id) => 'provider:$id';
  static String toolNode(String name) => 'tool:$name';

  /// Rebuilds structural nodes/edges from a state snapshot, keeping event-derived ones.
  void applyState(EngineState s) {
    for (final p in s.providers) {
      final n = _node(providerNode(p.id), GraphNodeKind.provider, p.name);
      n.state = p.enabled ? null : 'disabled';
    }
    for (final k in s.keys) {
      final n = _node(keyNode(k.id), GraphNodeKind.key, k.name);
      n.state = k.circuitState;
      n.detail = k.masked;
      _edge(keyNode(k.id), providerNode(k.providerId), structural: true);
      final p = nodes[providerNode(k.providerId)];
      if (p != null && p.state == null) p.state = 'closed';
    }
    for (final a in s.availability) {
      if (a.status != 'available') continue;
      _node(modelNode(a.modelId), GraphNodeKind.model, a.modelId);
      if (nodes.containsKey(keyNode(a.keyId))) _edge(modelNode(a.modelId), keyNode(a.keyId), structural: true);
    }
    for (final c in s.circuits) {
      // Circuit ids: provider = `p`, key = `p/keyId`, model = `p/keyId/model`.
      final id = c.level == 'provider'
          ? providerNode(c.id)
          : (c.level == 'key' && c.id.contains('/') ? keyNode(c.id.substring(c.id.indexOf('/') + 1)) : null);
      final n = id == null ? null : nodes[id];
      if (n != null) n.state = c.state;
    }
    layout();
    revision++;
  }

  /// Applies one real event. Returns true when something visible changed.
  bool applyEvent(EngineEvent e) {
    revision++;
    final ts = e.ts;
    switch (e.type) {
      case 'MODEL_REQUEST_STARTED':
        final rid = e.requestId;
        final model = jStr(e.data['modelId']) ?? e.modelId;
        if (rid == null || model == null) return false;
        final agent = agentId(e.agentId);
        _node(agent, GraphNodeKind.agent, e.agentId ?? 'Unattributed client');
        _node(modelNode(model), GraphNodeKind.model, model);
        _reqRoute[rid] = (agent: agent, model: modelNode(model));
        if (_reqRoute.length > 500) _reqRoute.remove(_reqRoute.keys.first);
        _pulse(agent, modelNode(model), ts);
      case 'KEY_SELECTED':
        final r = e.requestId == null ? null : _reqRoute[e.requestId];
        final k = e.keyId, p = e.providerId;
        if (k == null) return false;
        final model = e.modelId != null ? modelNode(e.modelId!) : r?.model;
        _node(keyNode(k), GraphNodeKind.key, k);
        if (model != null) {
          _node(model, GraphNodeKind.model, model.substring(6));
          _pulse(model, keyNode(k), ts);
        }
        if (p != null) {
          _node(providerNode(p), GraphNodeKind.provider, p);
          _pulse(keyNode(k), providerNode(p), ts);
        }
      case 'MODEL_REQUEST_FAILED':
      case 'FAILOVER':
        final k = e.keyId ?? jStr(e.data['fromKeyId']);
        final p = e.providerId;
        if (k != null && nodes.containsKey(keyNode(k)) && p != null) {
          _pulse(keyNode(k), providerNode(p), ts, failed: true);
        }
      case 'MODEL_FIRST_TOKEN':
      case 'MODEL_REQUEST_COMPLETE':
        final k = e.keyId, p = e.providerId;
        if (k != null && p != null && nodes.containsKey(keyNode(k))) _pulse(providerNode(p), keyNode(k), ts);
      case 'CIRCUIT_OPENED':
      case 'CIRCUIT_HALF_OPEN':
      case 'CIRCUIT_CLOSED':
      case 'CIRCUIT_STATE_CHANGED':
        final to = jStr(e.data['to']);
        final level = jStr(e.data['level']);
        final target = level == 'provider'
            ? (e.providerId == null ? null : nodes[providerNode(e.providerId!)])
            : level == 'key'
                ? (e.keyId == null ? null : nodes[keyNode(e.keyId!)])
                : null;
        if (target != null && to != null) {
          target
            ..state = to
            ..lastEventAt = ts;
        }
      case 'TOOL_STARTED':
      case 'TOOL_COMPLETE':
      case 'TOOL_FAILED':
        final tool = jStr(e.data['tool']);
        if (tool == null) return false;
        final agent = agentId(e.agentId);
        _node(agent, GraphNodeKind.agent, e.agentId ?? 'Unattributed client');
        _node(toolNode(tool), GraphNodeKind.tool, tool);
        _pulse(agent, toolNode(tool), ts, failed: e.type == 'TOOL_FAILED');
      default:
        return false;
    }
    layout();
    return true;
  }

  /// Edges with a pulse inside [pulseWindow] of [now]. The painter animates only these.
  List<GraphEdge> activeEdges(DateTime now) =>
      edges.values.where((e) => e.lastPulseAt != null && now.difference(e.lastPulseAt!) < pulseWindow).toList(growable: false);

  /// 0..1 progress of an edge's pulse (0 = just fired), or null when idle.
  double? pulseProgress(GraphEdge e, DateTime now) {
    final at = e.lastPulseAt;
    if (at == null) return null;
    final d = now.difference(at);
    if (d >= pulseWindow || d.isNegative) return null;
    return d.inMilliseconds / pulseWindow.inMilliseconds;
  }

  GraphNode _node(String id, GraphNodeKind kind, String label) {
    final n = nodes.putIfAbsent(id, () => GraphNode(id: id, kind: kind, label: label));
    if (n.label != label && label.isNotEmpty && n.kind != GraphNodeKind.agent) n.label = label;
    return n;
  }

  GraphEdge _edge(String from, String to, {bool structural = false}) {
    final id = '$from>$to';
    final e = edges.putIfAbsent(id, () => GraphEdge(from, to, structural: structural));
    if (structural) e.structural = true;
    return e;
  }

  void _pulse(String from, String to, DateTime at, {bool failed = false}) {
    final e = _edge(from, to);
    e.lastPulseAt = at;
    e.lastPulseFailed = failed;
    e.pulses++;
    nodes[from]?.lastEventAt = at;
    nodes[to]?.lastEventAt = at;
  }

  /// Columns: agents+tools | models | keys | providers.
  void layout() {
    final cols = <int, List<GraphNode>>{0: [], 1: [], 2: [], 3: []};
    for (final n in nodes.values) {
      cols[switch (n.kind) {
        GraphNodeKind.agent || GraphNodeKind.tool => 0,
        GraphNodeKind.model => 1,
        GraphNodeKind.key => 2,
        GraphNodeKind.provider => 3,
      }]!
          .add(n);
    }
    for (final entry in cols.entries) {
      final list = entry.value
        ..sort((a, b) {
          final k = a.kind.index.compareTo(b.kind.index);
          return k != 0 ? k : a.label.compareTo(b.label);
        });
      for (var i = 0; i < list.length; i++) {
        list[i].x = 0.08 + entry.key * (0.84 / 3);
        list[i].y = list.length == 1 ? 0.5 : 0.06 + 0.88 * (i / math.max(1, list.length - 1));
      }
    }
  }
}
