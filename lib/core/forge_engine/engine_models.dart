import 'json_util.dart';

/// Typed, defensive views of the engine's `GET /forge/state` JSON
/// (`ControlPlaneState` in `sdk/packages/forge/src/runtime.ts`) and of the
/// `GET /forge/events` SSE payloads (`ForgeEvent` in `events.ts`).
///
/// Rule: a field the engine did not send stays `null` (or an empty list). The
/// UI renders that as "unknown"/"no data"; nothing here ever invents a number.

// ---------------------------------------------------------------- usage ----

class EngineTokens {
  const EngineTokens({this.input = 0, this.output = 0, this.cachedInput = 0, this.cacheWrite = 0, this.reasoning = 0, this.total = 0});
  factory EngineTokens.fromJson(Object? v) {
    final j = jMap(v);
    return EngineTokens(
      input: jInt(j['input']) ?? 0,
      output: jInt(j['output']) ?? 0,
      cachedInput: jInt(j['cachedInput']) ?? 0,
      cacheWrite: jInt(j['cacheWrite']) ?? 0,
      reasoning: jInt(j['reasoning']) ?? 0,
      total: jInt(j['total']) ?? 0,
    );
  }
  final int input, output, cachedInput, cacheWrite, reasoning, total;
}

/// `Aggregate` from usage.ts: a sum over ledger records.
class EngineAggregate {
  const EngineAggregate({
    this.calls = 0,
    this.failures = 0,
    this.tokens = const EngineTokens(),
    this.cost = 0,
    this.costCurrency,
    this.estimatedRecords = 0,
    this.avgLatencyMs,
    this.avgTtftMs,
  });
  factory EngineAggregate.fromJson(Object? v) {
    final j = jMap(v);
    return EngineAggregate(
      calls: jInt(j['calls']) ?? 0,
      failures: jInt(j['failures']) ?? 0,
      tokens: EngineTokens.fromJson(j['tokens']),
      cost: jNum(j['cost']) ?? 0,
      costCurrency: jStr(j['costCurrency']),
      estimatedRecords: jInt(j['estimatedRecords']) ?? 0,
      avgLatencyMs: jNum(j['avgLatencyMs']),
      avgTtftMs: jNum(j['avgTtftMs']),
    );
  }
  final int calls, failures, estimatedRecords;
  final EngineTokens tokens;
  final double cost;
  final String? costCurrency;
  final double? avgLatencyMs, avgTtftMs;

  /// Cost is only meaningful when some call was priced (a currency was reported).
  bool get hasCost => costCurrency != null;
  double? get failureRate => calls == 0 ? null : failures / calls;
}

// ------------------------------------------------------------- circuits ----

class EngineCircuit {
  const EngineCircuit({
    required this.id,
    required this.level,
    required this.state,
    this.reason,
    this.failuresInWindow = 0,
    this.distinctSources = 0,
    this.trips = 0,
    this.openUntil,
    this.cooldownUntil,
    this.nextProbeAt,
    this.lastFailureKind,
    this.lastFailureAt,
    this.needsAttention = false,
  });
  factory EngineCircuit.fromJson(Map<String, dynamic> j) => EngineCircuit(
        id: jStr(j['id']) ?? '?',
        level: jStr(j['level']) ?? 'key',
        state: jStr(j['state']) ?? 'unknown',
        reason: jStr(j['reason']),
        failuresInWindow: jInt(j['failuresInWindow']) ?? 0,
        distinctSources: jInt(j['distinctSources']) ?? 0,
        trips: jInt(j['trips']) ?? 0,
        openUntil: jInt(j['openUntil']),
        cooldownUntil: jInt(j['cooldownUntil']),
        nextProbeAt: jInt(j['nextProbeAt']),
        lastFailureKind: jStr(j['lastFailureKind']),
        lastFailureAt: jInt(j['lastFailureAt']),
        needsAttention: jBool(j['needsAttention']) ?? false,
      );

  final String id;

  /// `provider` | `key` | `model`.
  final String level;

  /// closed, degraded, half_open, open, cooldown, disabled, exhausted (or `unknown`).
  final String state;
  final String? reason, lastFailureKind;
  final int failuresInWindow, distinctSources, trips;
  final int? openUntil, cooldownUntil, nextProbeAt, lastFailureAt;
  final bool needsAttention;

  bool get isClosed => state == 'closed';

  /// States in which the engine will not route traffic through this circuit.
  bool get blocksTraffic => const {'open', 'cooldown', 'disabled', 'exhausted'}.contains(state);
}

// ------------------------------------------------------------- capacity ----

class EngineLimitStatus {
  const EngineLimitStatus({required this.name, required this.used, this.max, this.remaining, this.fraction, required this.source, required this.status, this.resetsAt});
  factory EngineLimitStatus.fromJson(Map<String, dynamic> j) => EngineLimitStatus(
        name: jStr(j['name']) ?? '?',
        used: jNum(j['used']) ?? 0,
        max: jNum(j['max']),
        remaining: jNum(j['remaining']),
        fraction: jNum(j['fraction']),
        source: jStr(j['source']) ?? 'unknown',
        status: jStr(j['status']) ?? 'unknown',
        resetsAt: jInt(j['resetsAt']),
      );
  final String name, source, status;
  final double used;
  final double? max, remaining, fraction;
  final int? resetsAt;
}

class EngineCapacity {
  const EngineCapacity({this.limits = const [], this.worst = 'unknown', this.providerQuotaKnown = false, this.minRemainingFraction});
  factory EngineCapacity.fromJson(Object? v) {
    final j = jMap(v);
    return EngineCapacity(
      limits: jList(j['limits'], EngineLimitStatus.fromJson),
      worst: jStr(j['worst']) ?? 'unknown',
      providerQuotaKnown: j['providerQuota'] == 'known',
      minRemainingFraction: jNum(j['minRemainingFraction']),
    );
  }
  final List<EngineLimitStatus> limits;

  /// healthy, unknown, warning, critical, exhausted.
  final String worst;

  /// False means "Provider quota: Unknown" (no limit came from the provider).
  final bool providerQuotaKnown;
  final double? minRemainingFraction;
}

class EngineHealthFactor {
  const EngineHealthFactor({required this.name, this.value, required this.weight, required this.detail});
  factory EngineHealthFactor.fromJson(Map<String, dynamic> j) => EngineHealthFactor(
        name: jStr(j['name']) ?? '?',
        value: jNum(j['value']),
        weight: jNum(j['weight']) ?? 0,
        detail: jStr(j['detail']) ?? '',
      );
  final String name, detail;
  final double? value;
  final double weight;
}

class EngineHealth {
  const EngineHealth({this.score, this.factors = const [], this.sampleSize = 0});
  factory EngineHealth.fromJson(Object? v) {
    final j = jMap(v);
    return EngineHealth(
      score: jNum(j['score']),
      factors: jList(j['factors'], EngineHealthFactor.fromJson),
      sampleSize: jInt(j['sampleSize']) ?? 0,
    );
  }

  /// Null when the engine has no measurements yet (never a default of 100).
  final double? score;
  final List<EngineHealthFactor> factors;
  final int sampleSize;
}

// ------------------------------------------------------- providers/keys ----

class EngineProvider {
  const EngineProvider({required this.id, required this.name, required this.kind, required this.enabled});
  factory EngineProvider.fromJson(Map<String, dynamic> j) => EngineProvider(
        id: jStr(j['id']) ?? '?',
        name: jStr(j['name']) ?? jStr(j['id']) ?? '?',
        kind: jStr(j['kind']) ?? '',
        enabled: j['enabled'] != false,
      );
  final String id, name, kind;
  final bool enabled;
}

/// A vault key as the engine reports it. [masked] is the engine's own masked
/// display; the secret itself never leaves the engine.
class EngineKey {
  const EngineKey({
    required this.id,
    required this.name,
    required this.providerId,
    this.masked,
    required this.enabled,
    this.priority,
    this.circuit,
    this.capacity,
    this.health,
    this.last15m,
    this.p50LatencyMs,
    this.p95LatencyMs,
  });
  factory EngineKey.fromJson(Map<String, dynamic> j) {
    final c = j['circuit'];
    return EngineKey(
      id: jStr(j['id']) ?? '?',
      name: jStr(j['name']) ?? jStr(j['id']) ?? '?',
      providerId: jStr(j['providerId']) ?? '?',
      masked: jStr(j['masked']),
      enabled: j['enabled'] != false,
      priority: jInt(j['priority']),
      circuit: c is Map ? EngineCircuit.fromJson({'id': jStr(c['id']) ?? j['id'], 'level': 'key', ...c.cast<String, dynamic>()}) : null,
      capacity: j['capacity'] is Map ? EngineCapacity.fromJson(j['capacity']) : null,
      health: j['health'] is Map ? EngineHealth.fromJson(j['health']) : null,
      last15m: j['last15m'] is Map ? EngineAggregate.fromJson(j['last15m']) : null,
      p50LatencyMs: jNum(j['p50LatencyMs']),
      p95LatencyMs: jNum(j['p95LatencyMs']),
    );
  }
  final String id, name, providerId;
  final String? masked;
  final bool enabled;
  final int? priority;
  final EngineCircuit? circuit;
  final EngineCapacity? capacity;
  final EngineHealth? health;
  final EngineAggregate? last15m;
  final double? p50LatencyMs, p95LatencyMs;

  String get circuitState => circuit?.state ?? 'unknown';

  /// Enabled, circuit not blocking, capacity not exhausted.
  bool get canServe => enabled && !(circuit?.blocksTraffic ?? false) && capacity?.worst != 'exhausted';
}

class EngineActiveCall {
  const EngineActiveCall({required this.requestId, this.providerId, this.keyId, this.modelId, this.ageMs, this.tokens, this.streamTps, this.firstTokenAt});
  factory EngineActiveCall.fromJson(Map<String, dynamic> j) {
    final t = jMap(j['target']);
    return EngineActiveCall(
      requestId: jStr(j['requestId']) ?? jStr(j['id']) ?? '?',
      providerId: jStr(t['providerId']),
      keyId: jStr(t['keyId']),
      modelId: jStr(t['modelId']),
      ageMs: jNum(j['ageMs']),
      tokens: jInt(j['tokens']),
      streamTps: jNum(j['streamTps']),
      firstTokenAt: jInt(j['firstTokenAt']),
    );
  }
  final String requestId;
  final String? providerId, keyId, modelId;
  final double? ageMs, streamTps;
  final int? tokens, firstTokenAt;
}

// ---------------------------------------------------------------- guard ----

class EngineGuardSignal {
  const EngineGuardSignal({required this.kind, required this.scope, required this.level, required this.detail, this.ts});
  factory EngineGuardSignal.fromJson(Map<String, dynamic> j) => EngineGuardSignal(
        kind: jStr(j['kind']) ?? '?',
        scope: jStr(j['scope']) ?? '?',
        level: jStr(j['level']) ?? 'none',
        detail: jStr(j['detail']) ?? '',
        ts: jInt(j['ts']),
      );
  final String kind, scope, level, detail;
  final int? ts;
}

class EngineBurnReading {
  const EngineBurnReading({this.tokensPerMin, this.callsPerMin, this.costPerMin});
  factory EngineBurnReading.fromJson(Object? v) {
    final j = jMap(v);
    return EngineBurnReading(tokensPerMin: jNum(j['tokensPerMin']), callsPerMin: jNum(j['callsPerMin']), costPerMin: jNum(j['costPerMin']));
  }
  final double? tokensPerMin, callsPerMin, costPerMin;
}

class EngineGuardScope {
  const EngineGuardScope({
    required this.scope,
    required this.level,
    required this.paused,
    this.breakUntil,
    this.current = const EngineBurnReading(),
    this.baseline,
    this.tokensIncreasePct,
    this.signals = const [],
    this.duplicateRequests = 0,
    this.resentTokensEstimated = 0,
  });
  factory EngineGuardScope.fromJson(Map<String, dynamic> j) {
    final burn = jMap(j['burn']);
    final inc = jMap(burn['increasePct']);
    return EngineGuardScope(
      scope: jStr(j['scope']) ?? '?',
      level: jStr(j['level']) ?? 'none',
      paused: jBool(j['paused']) ?? false,
      breakUntil: jInt(j['breakUntil']),
      current: EngineBurnReading.fromJson(burn['current']),
      baseline: burn['baseline'] is Map ? EngineBurnReading.fromJson(burn['baseline']) : null,
      tokensIncreasePct: jNum(inc['tokens']),
      signals: jList(j['recentSignals'], EngineGuardSignal.fromJson),
      duplicateRequests: jInt(j['duplicateRequests']) ?? 0,
      resentTokensEstimated: jInt(j['resentTokensEstimated']) ?? 0,
    );
  }
  final String scope;

  /// none, warning, throttle, circuit_break, pause_task.
  final String level;
  final bool paused;
  final int? breakUntil;
  final EngineBurnReading current;
  final EngineBurnReading? baseline;
  final double? tokensIncreasePct;
  final List<EngineGuardSignal> signals;
  final int duplicateRequests, resentTokensEstimated;

  bool get needsAttention => paused || level != 'none';
}

// -------------------------------------------------------------- routing ----

class EngineCandidate {
  const EngineCandidate({required this.providerId, required this.keyId, required this.modelId, required this.rank, required this.why, required this.step, this.score});
  factory EngineCandidate.fromJson(Map<String, dynamic> j) {
    final t = jMap(j['target']);
    return EngineCandidate(
      providerId: jStr(t['providerId']) ?? '?',
      keyId: jStr(t['keyId']) ?? '?',
      modelId: jStr(t['modelId']) ?? '?',
      rank: jInt(j['rank']) ?? 0,
      why: jStr(j['why']) ?? '',
      step: jStr(j['step']) ?? '',
      score: jNum(j['score']),
    );
  }
  final String providerId, keyId, modelId, why, step;
  final int rank;
  final double? score;
}

class EngineRejection {
  const EngineRejection({required this.keyId, required this.modelId, required this.reason});
  factory EngineRejection.fromJson(Map<String, dynamic> j) =>
      EngineRejection(keyId: jStr(j['keyId']) ?? '?', modelId: jStr(j['modelId']) ?? '?', reason: jStr(j['reason']) ?? '');
  final String keyId, modelId, reason;
}

class EngineRoutingDecision {
  const EngineRoutingDecision({
    required this.requestId,
    required this.ts,
    required this.policy,
    required this.requestedModel,
    this.candidates = const [],
    this.rejected = const [],
    this.chosen,
    this.attempts = const [],
  });
  factory EngineRoutingDecision.fromJson(Map<String, dynamic> j) => EngineRoutingDecision(
        requestId: jStr(j['requestId']) ?? '?',
        ts: jInt(j['ts']) ?? 0,
        policy: jStr(j['policy']) ?? '?',
        requestedModel: jStr(j['requestedModel']) ?? '?',
        candidates: jList(j['candidates'], EngineCandidate.fromJson),
        rejected: jList(j['rejected'], EngineRejection.fromJson),
        chosen: j['chosen'] is Map ? EngineCandidate.fromJson(jMap(j['chosen'])) : null,
        attempts: jList(j['attempts'], EngineCandidate.fromJson),
      );
  final String requestId, policy, requestedModel;
  final int ts;
  final List<EngineCandidate> candidates;
  final List<EngineRejection> rejected;
  final EngineCandidate? chosen;
  final List<EngineCandidate> attempts;

  /// More than one attempt, or a non-preferred ladder step, means the router failed over.
  bool get failedOver => attempts.length > 1 || (chosen != null && chosen!.step != 'preferred');
}

class EngineRouting {
  const EngineRouting({this.policy, this.decisions = 0, this.failoversUsed = 0, this.byPolicy = const {}, this.rejectionReasons = const {}, this.recentDecisions = const []});
  factory EngineRouting.fromJson(Object? v) {
    final j = jMap(v);
    final s = jMap(j['stats']);
    Map<String, int> counts(Object? m) => {for (final e in jMap(m).entries) if (e.value is num) e.key: (e.value as num).toInt()};
    return EngineRouting(
      policy: jStr(j['policy']),
      decisions: jInt(s['decisions']) ?? 0,
      failoversUsed: jInt(s['failoversUsed']) ?? 0,
      byPolicy: counts(s['byPolicy']),
      rejectionReasons: counts(s['rejectionReasons']),
      recentDecisions: jList(j['recentDecisions'], EngineRoutingDecision.fromJson),
    );
  }
  final String? policy;
  final int decisions, failoversUsed;
  final Map<String, int> byPolicy, rejectionReasons;
  final List<EngineRoutingDecision> recentDecisions;
}

// --------------------------------------------------------------- alerts ----

class EngineNotification {
  const EngineNotification({
    required this.id,
    required this.ruleId,
    required this.kind,
    required this.severity,
    required this.title,
    required this.message,
    required this.ts,
    required this.scope,
    this.repeats = 0,
    this.acknowledged = false,
  });
  factory EngineNotification.fromJson(Map<String, dynamic> j) => EngineNotification(
        id: jStr(j['id']) ?? '?',
        ruleId: jStr(j['ruleId']) ?? '',
        kind: jStr(j['kind']) ?? '',
        severity: jStr(j['severity']) ?? 'information',
        title: jStr(j['title']) ?? '',
        message: jStr(j['message']) ?? '',
        ts: jInt(j['ts']) ?? 0,
        scope: jStr(j['scope']) ?? '',
        repeats: jInt(j['repeats']) ?? 0,
        acknowledged: jBool(j['acknowledged']) ?? false,
      );
  final String id, ruleId, kind, title, message, scope;

  /// information | success | warning | critical.
  final String severity;
  final int ts, repeats;
  final bool acknowledged;
  bool get isCritical => severity == 'critical';
}

// --------------------------------------------- availability/diagnostics ----

class EngineAvailability {
  const EngineAvailability({required this.providerId, required this.keyId, required this.keyName, required this.modelId, required this.status, this.checkedAt, this.stale = false, this.detail});
  factory EngineAvailability.fromJson(Map<String, dynamic> j) => EngineAvailability(
        providerId: jStr(j['providerId']) ?? '?',
        keyId: jStr(j['keyId']) ?? '?',
        keyName: jStr(j['keyName']) ?? '?',
        modelId: jStr(j['modelId']) ?? '?',
        status: jStr(j['status']) ?? 'unknown',
        checkedAt: jInt(j['checkedAt']),
        stale: jBool(j['stale']) ?? false,
        detail: jStr(j['detail']),
      );
  final String providerId, keyId, keyName, modelId, status;
  final int? checkedAt;
  final bool stale;
  final String? detail;
}

class EngineAnalyticsStats {
  const EngineAnalyticsStats({this.queued = 0, this.dropped = 0, this.written = 0, this.corruptLines = 0, this.rawBytes = 0, this.lastError});
  factory EngineAnalyticsStats.fromJson(Object? v) {
    final j = jMap(v);
    return EngineAnalyticsStats(
      queued: jInt(j['queued']) ?? 0,
      dropped: jInt(j['dropped']) ?? 0,
      written: jInt(j['written']) ?? 0,
      corruptLines: jInt(j['corruptLines']) ?? 0,
      rawBytes: jInt(j['rawBytes']) ?? 0,
      lastError: jStr(j['lastError']),
    );
  }
  final int queued, dropped, written, corruptLines, rawBytes;
  final String? lastError;
}

class EngineConfigStatus {
  const EngineConfigStatus({this.path, this.present = false, this.errors = const [], this.warnings = const []});
  factory EngineConfigStatus.fromJson(Object? v) {
    final j = jMap(v);
    String msg(Map<String, dynamic> e) => '${jStr(e['path']) ?? ''} ${jStr(e['message']) ?? ''}'.trim();
    return EngineConfigStatus(
      path: jStr(j['path']),
      present: jBool(j['present']) ?? false,
      errors: jList(j['errors'], msg),
      warnings: jList(j['warnings'], msg),
    );
  }
  final String? path;
  final bool present;
  final List<String> errors, warnings;
}

// ---------------------------------------------------------------- state ----

class EngineState {
  const EngineState({
    required this.now,
    this.providers = const [],
    this.keys = const [],
    this.active = const [],
    this.circuits = const [],
    this.totals = const EngineAggregate(),
    this.totalsAllTime = const EngineAggregate(),
    this.lastEventSeq = 0,
    this.guard = const [],
    this.routing = const EngineRouting(),
    this.unreadNotifications = 0,
    this.notifications = const [],
    this.diagnostics = const {},
    this.analytics = const EngineAnalyticsStats(),
    this.availability = const [],
    this.config = const EngineConfigStatus(),
  });

  factory EngineState.fromJson(Map<String, dynamic> j) {
    final n = jMap(j['notifications']);
    return EngineState(
      now: jInt(j['now']) ?? 0,
      providers: jList(j['providers'], EngineProvider.fromJson),
      keys: jList(j['keys'], EngineKey.fromJson),
      active: jList(j['active'], EngineActiveCall.fromJson),
      circuits: jList(j['circuits'], EngineCircuit.fromJson),
      totals: EngineAggregate.fromJson(j['totals']),
      totalsAllTime: EngineAggregate.fromJson(j['totalsAllTime']),
      lastEventSeq: jInt(j['lastEventSeq']) ?? 0,
      guard: jList(j['guard'], EngineGuardScope.fromJson),
      routing: EngineRouting.fromJson(j['routing']),
      unreadNotifications: jInt(n['unread']) ?? 0,
      notifications: jList(n['recent'], EngineNotification.fromJson),
      diagnostics: jMap(j['diagnostics']),
      analytics: EngineAnalyticsStats.fromJson(j['analytics']),
      availability: jList(j['availability'], EngineAvailability.fromJson),
      config: EngineConfigStatus.fromJson(j['config']),
    );
  }

  /// Engine clock (ms since epoch) when the snapshot was taken.
  final int now;
  final List<EngineProvider> providers;
  final List<EngineKey> keys;
  final List<EngineActiveCall> active;

  /// Circuits that are not closed (or have tripped before), as the engine filters them.
  final List<EngineCircuit> circuits;

  /// Production usage in the last 15 minutes / all time (test traffic excluded by the engine).
  final EngineAggregate totals, totalsAllTime;
  final int lastEventSeq;
  final List<EngineGuardScope> guard;
  final EngineRouting routing;
  final int unreadNotifications;
  final List<EngineNotification> notifications;

  /// Raw `SelfDiagnostics.report()`; its shape is owned by the engine.
  final Map<String, dynamic> diagnostics;
  final EngineAnalyticsStats analytics;
  final List<EngineAvailability> availability;
  final EngineConfigStatus config;

  List<EngineKey> keysOf(String providerId) => keys.where((k) => k.providerId == providerId).toList(growable: false);
  EngineKey? keyById(String id) {
    for (final k in keys) {
      if (k.id == id) return k;
    }
    return null;
  }

  EngineProvider? providerById(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Keys that can take a request right now.
  int get servableKeys => keys.where((k) => k.canServe).length;
}

// --------------------------------------------------------------- events ----

class EngineEvent {
  const EngineEvent({required this.seq, required this.ts, required this.type, this.correlation = const {}, this.target = const {}, this.data = const {}});

  /// Returns null for anything that is not a well-formed event.
  static EngineEvent? tryParse(Object? j) {
    if (j is! Map) return null;
    final seq = jInt(j['seq']);
    final type = jStr(j['type']);
    if (seq == null || type == null) return null;
    return EngineEvent(
      seq: seq,
      ts: DateTime.fromMillisecondsSinceEpoch(jInt(j['ts']) ?? 0),
      type: type,
      correlation: jMap(j['correlation']),
      target: jMap(j['target']),
      data: jMap(j['data']),
    );
  }

  final int seq;
  final DateTime ts;
  final String type;
  final Map<String, dynamic> correlation, target, data;

  String? get requestId => jStr(correlation['requestId']);
  String? get agentId => jStr(correlation['agentId']);
  String? get sessionId => jStr(correlation['sessionId']);
  String? get taskId => jStr(correlation['taskId']);
  String? get providerId => jStr(target['providerId']);
  String? get keyId => jStr(target['keyId']);
  String? get modelId => jStr(target['modelId']);
}

/// Events after which aggregates in `/forge/state` have changed, so a client
/// should refresh the snapshot soon rather than wait for the next poll.
const engineStateChangingEvents = {
  'MODEL_REQUEST_COMPLETE',
  'MODEL_REQUEST_FAILED',
  'KEY_EXHAUSTED',
  'FAILOVER',
  'CIRCUIT_OPENED',
  'CIRCUIT_HALF_OPEN',
  'CIRCUIT_CLOSED',
  'CIRCUIT_STATE_CHANGED',
  'ALERT',
  'GUARD',
};
