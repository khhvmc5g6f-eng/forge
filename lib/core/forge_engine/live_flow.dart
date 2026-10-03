import 'engine_models.dart';
import 'json_util.dart';

enum FlowStage {
  /// MODEL_REQUEST_STARTED: the request reached the gateway.
  uploading,

  /// KEY_SELECTED: a key was chosen and the call is on its way upstream.
  waiting,

  /// MODEL_FIRST_TOKEN: the upstream is answering.
  streaming,

  /// FAILOVER happened, the next candidate has not been selected yet.
  retrying,

  /// MODEL_REQUEST_COMPLETE.
  complete,

  /// MODEL_REQUEST_FAILED.
  failed,
}

class FlowFailover {
  const FlowFailover({required this.fromKey, this.toKey, this.kind, this.status});
  final String? fromKey, toKey, kind;
  final int? status;
}

class FlowRequest {
  FlowRequest({required this.requestId, required this.startedAt});
  final String requestId;
  final DateTime startedAt;
  DateTime? endedAt, firstTokenAt;
  FlowStage stage = FlowStage.uploading;
  String? agentId, sessionId, taskId, modelId, providerId, keyId, failureReason;
  int attempts = 0;
  int? ttftMs, latencyMs, outputTokens;
  final List<FlowFailover> failovers = [];

  /// Seen only through SSE replay of old events: never shown as in flight.
  bool historical = false;

  bool get inFlight => !historical && stage != FlowStage.complete && stage != FlowStage.failed;
  bool get terminal => stage == FlowStage.complete || stage == FlowStage.failed;
}

class FlowTool {
  FlowTool({required this.id, required this.tool, required this.startedAt});
  final String id, tool;
  final DateTime startedAt;
  DateTime? endedAt;
  String? sessionId, agentId;
  bool failed = false;
  bool get inFlight => endedAt == null;
}

/// Folds real engine events into "what is in flight right now". It has no
/// timers and invents nothing: no event, no motion. Events older than
/// [historyAfter] (SSE replay of the engine's buffer on connect) are recorded
/// as history and never shown as in flight.
class LiveFlowModel {
  LiveFlowModel({this.maxRecent = 40, this.historyAfter = const Duration(minutes: 2)});

  final int maxRecent;
  final Duration historyAfter;
  final Map<String, FlowRequest> _byId = {};
  final Map<String, FlowTool> _tools = {};
  final List<FlowRequest> _recent = [];
  final List<FlowTool> _recentTools = [];

  /// Incremented on every state change, so painters know when to repaint.
  int revision = 0;

  List<FlowRequest> get inFlight => _byId.values.where((r) => r.inFlight).toList(growable: false);
  int get trackedCount => _byId.length;
  List<FlowRequest> get recent => List.unmodifiable(_recent);
  List<FlowTool> get toolsInFlight => _tools.values.where((t) => t.inFlight).toList(growable: false);
  List<FlowTool> get recentTools => List.unmodifiable(_recentTools);
  bool get hasActivity => inFlight.isNotEmpty || toolsInFlight.isNotEmpty;

  void clear() {
    _byId.clear();
    _tools.clear();
    _recent.clear();
    _recentTools.clear();
    revision++;
  }

  void ingest(EngineEvent e, {required DateTime now}) {
    final old = now.difference(e.ts) > historyAfter;
    revision++;
    if (e.type.startsWith('TOOL_')) {
      _tool(e, old);
      return;
    }
    final id = e.requestId;
    if (id == null) return;
    switch (e.type) {
      case 'MODEL_REQUEST_STARTED':
        final r = _byId.putIfAbsent(id, () => FlowRequest(requestId: id, startedAt: e.ts));
        _tag(r, e);
        r.modelId = jStr(e.data['modelId']) ?? r.modelId;
        r.stage = FlowStage.uploading;
        if (old) r.historical = true;
      case 'KEY_SELECTED':
        final r = _byId.putIfAbsent(id, () => FlowRequest(requestId: id, startedAt: e.ts));
        _tag(r, e);
        r.attempts++;
        r.stage = FlowStage.waiting;
      case 'MODEL_FIRST_TOKEN':
        final r = _byId[id];
        if (r == null) return;
        r.firstTokenAt = e.ts;
        r.ttftMs = jInt(e.data['ttftMs']);
        if (r.inFlight) r.stage = FlowStage.streaming;
      case 'FAILOVER':
        final r = _byId[id];
        if (r == null) return;
        r.failovers.add(FlowFailover(
          fromKey: jStr(e.data['from']),
          toKey: jStr(e.data['toKey']),
          kind: jStr(e.data['kind']),
          status: jInt(e.data['status']),
        ));
        if (r.inFlight) r.stage = FlowStage.retrying;
      case 'MODEL_TOKEN_USAGE':
        final r = _byId[id];
        if (r == null) return;
        final t = jMap(e.data['tokens']);
        r.outputTokens = jInt(t['output']) ?? r.outputTokens;
      case 'MODEL_REQUEST_COMPLETE':
        final r = _byId[id];
        if (r == null) return;
        r.latencyMs = jInt(e.data['latencyMs']);
        r.ttftMs ??= jInt(e.data['ttftMs']);
        _finish(r, e.ts, FlowStage.complete, null);
      case 'MODEL_REQUEST_FAILED':
        // Failures can arrive without a STARTED (guard / budget refusals).
        final r = _byId.putIfAbsent(id, () => FlowRequest(requestId: id, startedAt: e.ts));
        _tag(r, e);
        final reason = jStr(e.data['reason']) ?? jStr(e.data['kind']) ?? 'failed';
        // A failure inside a failover chain is followed by FAILOVER / KEY_SELECTED, not an end.
        final terminal = const {'attempts_exhausted', 'no_eligible_key', 'guard_blocked', 'client_cancelled'}.contains(reason) ||
            e.data['partial'] == true ||
            reason.startsWith('forge_') ||
            r.stage == FlowStage.uploading && r.attempts == 0;
        if (terminal) {
          _finish(r, e.ts, FlowStage.failed, reason);
        } else {
          r.failureReason = reason;
        }
    }
  }

  /// Drops in-flight requests the engine no longer lists as active, once they
  /// are older than [grace]. Protects against a lost terminal event.
  void reconcile(Set<String> activeRequestIds, {required DateTime now, Duration grace = const Duration(seconds: 15)}) {
    var changed = false;
    for (final r in _byId.values.toList()) {
      if (r.historical && now.difference(r.startedAt) > historyAfter * 2) {
        _byId.remove(r.requestId);
        continue;
      }
      if (r.inFlight && !activeRequestIds.contains(r.requestId) && now.difference(r.startedAt) > grace) {
        _finish(r, now, FlowStage.failed, 'engine no longer lists it as active');
        changed = true;
      }
    }
    if (changed) revision++;
  }

  void _tag(FlowRequest r, EngineEvent e) {
    r.agentId ??= e.agentId;
    r.sessionId ??= e.sessionId;
    r.taskId ??= e.taskId;
    r.providerId = e.providerId ?? r.providerId;
    r.keyId = e.keyId ?? r.keyId;
    r.modelId = e.modelId ?? r.modelId;
  }

  void _finish(FlowRequest r, DateTime at, FlowStage stage, String? reason) {
    r.stage = stage;
    r.endedAt = at;
    if (reason != null) r.failureReason = reason;
    _byId.remove(r.requestId);
    _recent.insert(0, r);
    if (_recent.length > maxRecent) _recent.removeLast();
  }

  void _tool(EngineEvent e, bool old) {
    final id = jStr(e.correlation['toolCallId']) ?? '${e.sessionId}:${jStr(e.data['tool'])}';
    switch (e.type) {
      case 'TOOL_STARTED':
        if (old) return;
        _tools[id] = FlowTool(id: id, tool: jStr(e.data['tool']) ?? 'tool', startedAt: e.ts)
          ..sessionId = e.sessionId
          ..agentId = e.agentId;
      case 'TOOL_COMPLETE':
      case 'TOOL_FAILED':
        final t = _tools.remove(id);
        if (t == null) return;
        t.endedAt = e.ts;
        t.failed = e.type == 'TOOL_FAILED';
        _recentTools.insert(0, t);
        if (_recentTools.length > maxRecent) _recentTools.removeLast();
    }
  }
}
