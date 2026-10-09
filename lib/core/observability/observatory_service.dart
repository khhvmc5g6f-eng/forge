/// Neural Observatory — the central service.
///
/// One shared service beneath the entire application (the design brief's
/// "most important design decision"): every surface — the in-session
/// panel, the Observatory workspace, the CLI, the self-improvement
/// engine — reads the same telemetry, so a diagnostic seen inside a
/// conversation is the same data the dashboards and reports show.
/// Recording APIs are synchronous and cheap (bounded in-memory series plus
/// a queued append); disk I/O happens on flush, never on the request path.
library;

import 'dart:async';

import 'anomaly.dart';
import 'context_window.dart';
import 'cost_model.dart';
import 'execution_trace.dart';
import 'model_scorecard.dart';
import 'resource_sampler.dart';
import 'rolling_stats.dart';
import 'telemetry.dart';
import 'telemetry_store.dart';
import 'token_rate.dart';

/// Masked status of one provider credential as the Control Plane sees it.
/// The key itself never appears — only an internal reference id.
class ProviderStatusRow {
  const ProviderStatusRow({
    required this.providerId,
    required this.keyRef,
    required this.circuitState,
    required this.requests,
    required this.failures,
    required this.rateLimited,
    required this.averageLatencyMs,
  });

  final String providerId;

  /// Internal credential reference (e.g. `key_8aac62a15e`), never the value.
  final String keyRef;
  final String circuitState;
  final int requests;
  final int failures;
  final int rateLimited;
  final int averageLatencyMs;

  bool get available => circuitState != 'open';
}

/// App-layer adapter hook: the Control Centre wires this to
/// `CircuitBreakerRegistry`/`CredentialVault`. Observability stays
/// decoupled from `lib/core/control_plane/` — this package knows only the
/// shape of the answer, not the breaker's internals.
typedef ProviderStatusReader = List<ProviderStatusRow> Function();

/// A recorded work unit. The session's own span id is [SessionRecord.id].
class SessionRecord {
  SessionRecord({
    required this.id,
    required this.label,
    this.taskId,
    required this.startedAt,
  });

  final String id;
  final String label;
  final String? taskId;
  final DateTime startedAt;
  DateTime? endedAt;
  String status = 'running';

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);
}

/// Read model the live in-session panel renders.
class SessionStats {
  const SessionStats({
    required this.record,
    required this.latency,
    required this.latencyValues,
    required this.tokensPerSecond,
    required this.toolDuration,
    required this.requests,
    required this.failures,
    required this.rateLimited,
    required this.toolCalls,
    required this.toolFailures,
    required this.errors,
    required this.agents,
    required this.promptTokens,
    required this.completionTokens,
    required this.cachedTokens,
    required this.costUsd,
    required this.costKnown,
    required this.modelsUsed,
    required this.contextUtilisation,
    required this.contextRemaining,
    required this.contextPrediction,
  });

  final SessionRecord record;

  /// Latency stats over the session's retained window.
  final RollingStats latency;

  /// Raw recent latency samples (the sparkline input — real values only).
  final List<double> latencyValues;

  /// Whole-request average output tokens/sec (calculated, not inter-token).
  final RollingStats tokensPerSecond;
  final RollingStats toolDuration;

  final int requests;
  final int failures;
  final int rateLimited;
  final int toolCalls;
  final int toolFailures;
  final int errors;
  final int agents;
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;

  /// Cost accumulated from configured pricing; null when any contributing
  /// request had no pricing (rendered "unavailable", never a partial sum).
  final double? costUsd;
  final bool costKnown;

  final List<String> modelsUsed;
  final double? contextUtilisation;
  final int? contextRemaining;
  final ContextExhaustionPrediction contextPrediction;
}

class _SessionState {
  _SessionState(this.record, this.context);

  final SessionRecord record;
  final ExecutionTrace trace = ExecutionTrace();
  final MetricSeries latencyMs = MetricSeries(name: 'model.latencyMs');
  final MetricSeries tokensPerSecond =
      MetricSeries(name: 'model.tokensPerSecond');
  final MetricSeries toolDurationMs = MetricSeries(name: 'tool.durationMs');
  final ContextWindowTracker context;

  int requests = 0;
  int failures = 0;
  int rateLimited = 0;
  int toolCalls = 0;
  int toolFailures = 0;
  int errors = 0;
  int agents = 0;
  int agentFailures = 0;
  int promptTokens = 0;
  int completionTokens = 0;
  int cachedTokens = 0;
  double? costUsd;
  bool costKnown = true;
  final Set<String> modelsUsed = {};
}

class ObservatoryService {
  ObservatoryService({
    TelemetryStore? telemetryStore,
    CostCalculator? costCalculator,
    this.contextCapacityTokens = 128000,
  })  : store = telemetryStore,
        cost = costCalculator ?? CostCalculator();

  final TelemetryStore? store;
  final CostCalculator cost;
  final int contextCapacityTokens;

  final AnomalyDetector detector = AnomalyDetector();
  final AlertCenter alerts = AlertCenter();

  /// Global (cross-session) series the health index and reports read.
  final MetricSeries globalLatencyMs = MetricSeries(name: 'global.latencyMs');
  final MetricSeries globalCpuPercent = MetricSeries(name: 'global.cpuPercent');
  final MetricSeries globalRssBytes = MetricSeries(name: 'global.rssBytes');
  final MetricSeries globalNetworkIn = MetricSeries(name: 'global.net.in');
  final MetricSeries globalNetworkOut = MetricSeries(name: 'global.net.out');
  final MetricSeries globalErrors = MetricSeries(name: 'global.errors');

  int globalRequests = 0;
  int globalFailures = 0;
  int globalAgentsStarted = 0;
  int globalAgentFailures = 0;
  int networkBytesInTotal = 0;
  int networkBytesOutTotal = 0;

  /// Wired by the app layer to the Control Plane (see [ProviderStatusReader]).
  ProviderStatusReader? providerStatusReader;

  final Map<String, _SessionState> _sessions = {};
  final Map<String, ModelScorecard> _scorecards = {};
  final Set<String> _knownFreeModels = {};
  String? _currentSessionId;

  static const int _anomalyWindow = 25;

  List<SessionRecord> get sessions {
    final records = _sessions.values.map((s) => s.record).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return records;
  }

  List<ModelScorecard> get scorecards => _scorecards.values.toList();

  ExecutionTrace? traceFor(String sessionId) => _sessions[sessionId]?.trace;

  SessionRecord beginSession({String label = 'session', String? taskId}) {
    final record = SessionRecord(
      id: 'sess_${DateTime.now().millisecondsSinceEpoch}_${newSpanId()}',
      label: label,
      taskId: taskId,
      startedAt: DateTime.now(),
    );
    final state = _SessionState(
      record,
      ContextWindowTracker(capacityTokens: contextCapacityTokens),
    );
    _sessions[record.id] = state;
    _currentSessionId = record.id;
    state.trace.addNode(TraceNode(
      id: record.id,
      kind: SpanKind.session,
      label: label,
      startedAt: record.startedAt,
    ));
    unawaited(_append(ObsSpan(
      spanId: record.id,
      traceId: record.id,
      kind: SpanKind.session,
      name: 'session.begin',
      sessionId: record.id,
      taskId: taskId,
      startedAt: record.startedAt,
      attributes: {'label': label},
    )));
    return record;
  }

  void endSession(String sessionId, {String status = 'completed'}) {
    final state = _sessions[sessionId];
    if (state == null) return;
    state.record
      ..endedAt = DateTime.now()
      ..status = status;
    state.trace.node(sessionId)?.endedAt = state.record.endedAt;
    unawaited(_append(ObsSpan(
      spanId: newSpanId(),
      traceId: sessionId,
      parentSpanId: sessionId,
      kind: SpanKind.session,
      name: 'session.end',
      sessionId: sessionId,
      taskId: state.record.taskId,
      startedAt: state.record.startedAt,
      endedAt: state.record.endedAt,
      attributes: {
        'status': status,
        'durationMs': state.record.duration.inMilliseconds,
        'requests': state.requests,
        'promptTokens': state.promptTokens,
        'completionTokens': state.completionTokens,
      },
    )));
  }

  /// Marks a model's free/paid status from the registry — keeps cost
  /// honesty: free-tier models are costed at $0 (their actual charge);
  /// unknown paid models report `unavailable`, never an approximation.
  void noteModel(String providerId, String modelName,
      {required bool freeTier}) {
    final key = '$providerId::$modelName';
    if (freeTier) {
      _knownFreeModels.add(key);
    } else {
      _knownFreeModels.remove(key);
    }
  }

  /// The instrumentation adapter the app layer hands to the agent
  /// runtime/orchestrator. Stamps the session/task correlation the
  /// runtime cannot know itself; falls back to the current (or an
  /// implicit ad-hoc) session so no event is silently dropped.
  AgentTelemetry telemetryFor({
    String? sessionId,
    String? taskId,
    String? parentAgentId,
  }) {
    final sid = sessionId ??
        _currentSessionId ??
        beginSession(label: 'ad-hoc', taskId: taskId).id;
    return _StampingTelemetry._(this, sid, taskId, parentAgentId);
  }

  Future<void> _append(ObsSpan span) async {
    final s = store;
    if (s == null) return;
    try {
      await s.append(span);
    } catch (_) {
      // The store counts its own failures; never break the caller.
    }
  }

  _SessionState _ensureState(String sessionId) {
    return _sessions.putIfAbsent(
      sessionId,
      () => _SessionState(
        SessionRecord(
          id: sessionId,
          label: 'implicit',
          startedAt: DateTime.now(),
        ),
        ContextWindowTracker(capacityTokens: contextCapacityTokens),
      ),
    );
  }

  void _agentStarted({
    required String sessionId,
    String? taskId,
    required String agentId,
    required String role,
    String? parentAgentId,
  }) {
    final state = _ensureState(sessionId);
    state.agents++;
    globalAgentsStarted++;
    final at = DateTime.now();
    state.trace.addNode(TraceNode(
      id: agentId,
      kind: SpanKind.agent,
      label: role,
      parentId: parentAgentId ?? sessionId,
      startedAt: at,
    ));
    unawaited(_append(ObsSpan(
      spanId: agentId,
      traceId: sessionId,
      parentSpanId: parentAgentId ?? sessionId,
      kind: SpanKind.agent,
      name: 'agent.start',
      sessionId: sessionId,
      taskId: taskId ?? state.record.taskId,
      agentId: agentId,
      agentRole: role,
      startedAt: at,
      attributes: {
        'role': role,
        'parentAgentId': parentAgentId ?? '',
      },
    )));
  }

  void _agentFinished({
    required String sessionId,
    String? taskId,
    required String agentId,
    required String role,
    required String status,
    required int iterations,
    required int promptTokens,
    required int completionTokens,
    required int cachedPromptTokens,
  }) {
    final state = _ensureState(sessionId);
    final at = DateTime.now();
    if (status != 'ok') {
      state.agentFailures++;
      globalAgentFailures++;
    }
    final node = state.trace.node(agentId);
    if (node != null) {
      node
        ..endedAt = at
        ..status = status == 'ok' ? SpanStatus.ok : SpanStatus.error
        ..promptTokens += promptTokens
        ..completionTokens += completionTokens;
    }
    unawaited(_append(ObsSpan(
      spanId: newSpanId(),
      traceId: sessionId,
      parentSpanId: agentId,
      kind: SpanKind.agent,
      name: 'agent.end',
      sessionId: sessionId,
      taskId: taskId ?? state.record.taskId,
      agentId: agentId,
      agentRole: role,
      startedAt: node?.startedAt ?? at,
      endedAt: at,
      attributes: {
        'status': status,
        'iterations': iterations,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'cachedPromptTokens': cachedPromptTokens,
      },
    )));
  }

  void _recordModelRequest({
    required String sessionId,
    String? taskId,
    String? agentId,
    String? role,
    required String providerId,
    required String modelName,
    required int latencyMs,
    int? ttftMs,
    required bool succeeded,
    bool rateLimited = false,
    required int promptTokens,
    required int completionTokens,
    required int cachedPromptTokens,
  }) {
    final now = DateTime.now();
    final state = _ensureState(sessionId);
    state.requests++;
    globalRequests++;
    if (!succeeded) {
      state.failures++;
      state.errors++;
      globalFailures++;
      globalErrors.add(now, 1);
    }
    if (rateLimited) state.rateLimited++;
    state.latencyMs.add(now, latencyMs.toDouble());
    globalLatencyMs.add(now, latencyMs.toDouble());
    state.promptTokens += promptTokens;
    state.completionTokens += completionTokens;
    state.cachedTokens += cachedPromptTokens;

    final key = '$providerId::$modelName';
    final rate = ChatRequestRate.calculate(
      completionTokens: completionTokens,
      latencyMs: latencyMs,
    );
    if (rate.tokensPerSecond != null) {
      state.tokensPerSecond.add(now, rate.tokensPerSecond!);
    }

    final card = _scorecards.putIfAbsent(
      key,
      () => ModelScorecard(
        providerId: providerId,
        modelName: modelName,
        freeTier: _knownFreeModels.contains(key),
      ),
    );
    final costResult = cost.estimate(
      providerId: providerId,
      modelName: modelName,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedPromptTokens: cachedPromptTokens,
      modelIsFree: card.freeTier,
    );
    if (costResult.available) {
      state.costUsd = (state.costUsd ?? 0) + costResult.usd!;
    } else {
      state.costKnown = false;
    }
    card.recordRequest(
      latencyMs: latencyMs,
      ttftMs: ttftMs,
      tokensPerSecond: rate.tokensPerSecond,
      succeeded: succeeded,
      rateLimited: rateLimited,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      costUsd: costResult.usd,
    );
    state.modelsUsed.add(key);

    final agentNode = agentId == null ? null : state.trace.node(agentId);
    final spanId = newSpanId();
    state.trace.addNode(TraceNode(
      id: spanId,
      kind: SpanKind.model,
      label: key,
      parentId: agentNode?.id ?? sessionId,
      startedAt: now.subtract(Duration(milliseconds: latencyMs)),
      endedAt: now,
      status: succeeded ? SpanStatus.ok : SpanStatus.error,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      costUsd: costResult.usd,
    ));

    final window = state.latencyMs.samples.map((s) => s.value).toList();
    if (window.length > _anomalyWindow) {
      window.removeRange(0, window.length - _anomalyWindow);
    }
    final spike = detector.evaluateSpike(
      metric: 'model.latencyMs [$key]',
      window: window,
      affected: key,
      probableCause: 'Provider latency spike versus the session baseline.',
      recommendedInvestigation:
          'Check the provider circuit in the Control Centre and the retry log.',
    );
    if (spike != null) alerts.add(spike);

    unawaited(_append(ObsSpan(
      spanId: spanId,
      traceId: sessionId,
      parentSpanId: agentNode?.id ?? sessionId,
      kind: SpanKind.model,
      name: 'model.request',
      sessionId: sessionId,
      taskId: taskId ?? state.record.taskId,
      agentId: agentId,
      agentRole: role,
      startedAt: now.subtract(Duration(milliseconds: latencyMs)),
      endedAt: now,
      status: succeeded ? SpanStatus.ok : SpanStatus.error,
      attributes: {
        'model': key,
        'latencyMs': latencyMs,
        'latencyMs.quality': 'measured',
        'ttftMs': ttftMs,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'cachedPromptTokens': cachedPromptTokens,
        'tokensPerSecond': rate.tokensPerSecond,
        'tokensPerSecond.quality': 'calculated',
        'costUsd': costResult.usd,
        'costUsd.quality': costResult.available ? 'calculated' : 'unavailable',
        'succeeded': succeeded,
        'rateLimited': rateLimited,
      },
    )));
  }

  void _recordToolCall({
    required String sessionId,
    String? taskId,
    required String agentId,
    required String role,
    required String toolName,
    required int durationMs,
    required bool succeeded,
    required String decision,
  }) {
    final now = DateTime.now();
    final state = _ensureState(sessionId);
    state.toolCalls++;
    if (!succeeded) state.toolFailures++;
    state.toolDurationMs.add(now, durationMs.toDouble());

    final agentNode = state.trace.node(agentId);
    final spanId = newSpanId();
    state.trace.addNode(TraceNode(
      id: spanId,
      kind: SpanKind.tool,
      label: toolName,
      parentId: agentNode?.id ?? sessionId,
      startedAt: now.subtract(Duration(milliseconds: durationMs)),
      endedAt: now,
      status: succeeded ? SpanStatus.ok : SpanStatus.error,
      errorCount: succeeded ? 0 : 1,
    ));

    unawaited(_append(ObsSpan(
      spanId: spanId,
      traceId: sessionId,
      parentSpanId: agentNode?.id ?? sessionId,
      kind: SpanKind.tool,
      name: 'tool.call',
      sessionId: sessionId,
      taskId: taskId ?? state.record.taskId,
      agentId: agentId,
      agentRole: role,
      startedAt: now.subtract(Duration(milliseconds: durationMs)),
      endedAt: now,
      status: succeeded ? SpanStatus.ok : SpanStatus.error,
      attributes: {
        'tool': toolName,
        'durationMs': durationMs,
        'durationMs.quality': 'measured',
        'decision': decision,
        'succeeded': succeeded,
      },
    )));
  }

  /// Passive network sample from [CountingHttpClient] — real application
  /// traffic, labelled as such (never presented as connection speed).
  void recordNetworkTraffic({
    required int bytesOut,
    required int bytesIn,
    Uri? url,
  }) {
    final now = DateTime.now();
    networkBytesInTotal += bytesIn;
    networkBytesOutTotal += bytesOut;
    globalNetworkIn.add(now, bytesIn.toDouble());
    globalNetworkOut.add(now, bytesOut.toDouble());
    unawaited(_append(ObsSpan(
      spanId: newSpanId(),
      traceId: 'network',
      kind: SpanKind.network,
      name: 'network.traffic',
      sessionId: 'global',
      startedAt: now,
      endedAt: now,
      attributes: {
        'bytesIn': bytesIn,
        'bytesOut': bytesOut,
        'bytesIn.quality': 'measured',
        'host': url?.host ?? '',
      },
    )));
  }

  /// One host resource sample (see [ResourceSampler]).
  Future<void> recordResourceSample(ResourceSample sample) async {
    if (sample.cpuPercent != null) {
      globalCpuPercent.add(sample.at, sample.cpuPercent!);
    }
    if (sample.rssBytes != null) {
      globalRssBytes.add(sample.at, sample.rssBytes!.toDouble());
    }
    await _append(ObsSpan(
      spanId: newSpanId(),
      traceId: 'resources',
      kind: SpanKind.resource,
      name: 'resource.sample',
      sessionId: 'global',
      startedAt: sample.at,
      endedAt: sample.at,
      attributes: {
        'cpuPercent': sample.cpuPercent,
        'cpuPercent.quality': sample.cpuQuality.name,
        'rssBytes': sample.rssBytes,
        'rssBytes.quality': sample.ramQuality.name,
        // Always named so the UI can render "unavailable", not a guess.
        'gpuPercent.quality': sample.gpuQuality.name,
      },
    ));
  }

  /// Context-window observation for a session (prompt-side tokens).
  void recordContextUsage({
    String? sessionId,
    required int usedTokens,
    required int cachedTokens,
  }) {
    final sid = sessionId ?? _currentSessionId;
    if (sid == null) return;
    _ensureState(sid).context.observe(usedTokens, cachedTokens);
  }

  /// The read model for the in-session live panel; null for unknown ids.
  SessionStats? liveSessionStats(String sessionId) {
    final state = _sessions[sessionId];
    if (state == null) return null;
    return SessionStats(
      record: state.record,
      latency: _statsOf(state.latencyMs),
      latencyValues:
          state.latencyMs.samples.map((s) => s.value).toList(growable: false),
      tokensPerSecond: _statsOf(state.tokensPerSecond),
      toolDuration: _statsOf(state.toolDurationMs),
      requests: state.requests,
      failures: state.failures,
      rateLimited: state.rateLimited,
      toolCalls: state.toolCalls,
      toolFailures: state.toolFailures,
      errors: state.errors,
      agents: state.agents,
      promptTokens: state.promptTokens,
      completionTokens: state.completionTokens,
      cachedTokens: state.cachedTokens,
      costUsd: state.costKnown ? state.costUsd : null,
      costKnown: state.costKnown,
      modelsUsed: state.modelsUsed.toList()..sort(),
      contextUtilisation: state.context.utilisationFraction,
      contextRemaining: state.context.remainingTokens,
      contextPrediction: state.context.predictExhaustion(),
    );
  }

  static RollingStats _statsOf(MetricSeries series) {
    final stats = RollingStats(window: series.window);
    for (final s in series.samples) {
      stats.add(s.value);
    }
    return stats;
  }

}

/// The [AgentTelemetry] adapter returned by
/// [ObservatoryService.telemetryFor]: stamps the session/task correlation
/// (which the agent runtime has no way to know) onto every event before
/// forwarding to the service's recording internals.
class _StampingTelemetry implements AgentTelemetry {
  _StampingTelemetry._(
    this._service,
    this._sessionId,
    this._taskId,
    this._parentAgentId,
  );

  final ObservatoryService _service;
  final String _sessionId;
  final String? _taskId;
  final String? _parentAgentId;

  @override
  void agentStarted({
    required String agentId,
    required String role,
    String? parentAgentId,
  }) {
    _service._agentStarted(
      sessionId: _sessionId,
      taskId: _taskId,
      agentId: agentId,
      role: role,
      parentAgentId: parentAgentId ?? _parentAgentId,
    );
  }

  @override
  void agentFinished({
    required String agentId,
    required String role,
    required String status,
    required int iterations,
    required int promptTokens,
    required int completionTokens,
    required int cachedPromptTokens,
  }) {
    _service._agentFinished(
      sessionId: _sessionId,
      taskId: _taskId,
      agentId: agentId,
      role: role,
      status: status,
      iterations: iterations,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedPromptTokens: cachedPromptTokens,
    );
  }

  @override
  void modelRequest({
    required String agentId,
    required String role,
    required String providerId,
    required String modelName,
    required int latencyMs,
    int? ttftMs,
    required bool succeeded,
    bool rateLimited = false,
    required int promptTokens,
    required int completionTokens,
    required int cachedPromptTokens,
  }) {
    _service._recordModelRequest(
      sessionId: _sessionId,
      taskId: _taskId,
      agentId: agentId,
      role: role,
      providerId: providerId,
      modelName: modelName,
      latencyMs: latencyMs,
      ttftMs: ttftMs,
      succeeded: succeeded,
      rateLimited: rateLimited,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      cachedPromptTokens: cachedPromptTokens,
    );
  }

  @override
  void toolCall({
    required String agentId,
    required String role,
    required String toolName,
    required int durationMs,
    required bool succeeded,
    required String decision,
  }) {
    _service._recordToolCall(
      sessionId: _sessionId,
      taskId: _taskId,
      agentId: agentId,
      role: role,
      toolName: toolName,
      durationMs: durationMs,
      succeeded: succeeded,
      decision: decision,
    );
  }
}






