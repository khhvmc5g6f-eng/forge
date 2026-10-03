/// Typed, defensive views of the Forge gateway's `/forge/state` JSON and
/// `/forge/events` SSE payloads. Missing values stay null: the UI shows
/// "unknown", never a made-up number.
class GatewayKey {
  GatewayKey({
    required this.id,
    required this.name,
    required this.providerId,
    required this.masked,
    required this.enabled,
    required this.circuitState,
    required this.healthScore,
    required this.requests15m,
    required this.p50LatencyMs,
    required this.p95LatencyMs,
  });

  factory GatewayKey.fromJson(Map<String, dynamic> j) {
    final circuit = j['circuit'];
    final health = j['health'];
    final win = j['last15m'];
    return GatewayKey(
      id: '${j['id']}',
      name: '${j['name'] ?? j['id']}',
      providerId: '${j['providerId']}',
      masked: j['masked'] as String?,
      enabled: j['enabled'] != false,
      circuitState: circuit is Map ? circuit['state'] as String? : null,
      healthScore: health is Map ? _num(health['score']) : null,
      requests15m: win is Map ? _num(win['calls'])?.toInt() : null,
      p50LatencyMs: _num(j['p50LatencyMs']),
      p95LatencyMs: _num(j['p95LatencyMs']),
    );
  }

  final String id;
  final String name;
  final String providerId;
  final String? masked;
  final bool enabled;
  final String? circuitState;
  final double? healthScore;
  final int? requests15m;
  final double? p50LatencyMs;
  final double? p95LatencyMs;
}

class GatewayActiveCall {
  GatewayActiveCall({required this.id, required this.ageMs, required this.tokens, required this.streamTps});

  factory GatewayActiveCall.fromJson(Map<String, dynamic> j) => GatewayActiveCall(
        id: '${j['id'] ?? j['requestId'] ?? '?'}',
        ageMs: _num(j['ageMs']),
        tokens: _num(j['tokens'])?.toInt(),
        streamTps: _num(j['streamTps']),
      );

  final String id;
  final double? ageMs;
  final int? tokens;
  final double? streamTps;
}

class GatewayProvider {
  GatewayProvider({required this.id, required this.name, required this.kind, required this.enabled});

  factory GatewayProvider.fromJson(Map<String, dynamic> j) => GatewayProvider(
        id: '${j['id']}',
        name: '${j['name'] ?? j['id']}',
        kind: '${j['kind'] ?? ''}',
        enabled: j['enabled'] != false,
      );

  final String id;
  final String name;
  final String kind;
  final bool enabled;
}

class GatewayState {
  GatewayState({
    required this.providers,
    required this.keys,
    required this.active,
    required this.openCircuits,
    required this.lastEventSeq,
  });

  factory GatewayState.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) =>
        (j[k] as List? ?? const []).whereType<Map>().map((m) => f(m.cast<String, dynamic>())).toList();
    return GatewayState(
      providers: list('providers', GatewayProvider.fromJson),
      keys: list('keys', GatewayKey.fromJson),
      active: list('active', GatewayActiveCall.fromJson),
      openCircuits: (j['circuits'] as List? ?? const []).length,
      lastEventSeq: _num(j['lastEventSeq'])?.toInt() ?? 0,
    );
  }

  final List<GatewayProvider> providers;
  final List<GatewayKey> keys;
  final List<GatewayActiveCall> active;
  final int openCircuits;
  final int lastEventSeq;
}

class GatewayEvent {
  GatewayEvent({required this.seq, required this.ts, required this.type, required this.data});

  /// Returns null for anything that is not a well-formed event.
  static GatewayEvent? tryParse(Object? j) {
    if (j is! Map) return null;
    final seq = _num(j['seq']);
    final type = j['type'];
    if (seq == null || type is! String) return null;
    final data = j['data'];
    return GatewayEvent(
      seq: seq.toInt(),
      ts: DateTime.fromMillisecondsSinceEpoch((_num(j['ts']) ?? 0).toInt()),
      type: type,
      data: data is Map ? data.cast<String, dynamic>() : const {},
    );
  }

  final int seq;
  final DateTime ts;
  final String type;
  final Map<String, dynamic> data;
}

double? _num(Object? v) => v is num ? v.toDouble() : null;
