import 'circuit_breaker.dart';

/// Central home for every [CircuitBreaker] in the system — one per provider,
/// one per (provider, model), and (per the spec) one per tool/MCP server
/// where appropriate. Callers key breakers by a plain string id; this class
/// imposes no naming scheme beyond convention (`providerId` for a provider,
/// `providerId::modelName` for a model, `mcp:<serverId>` for an MCP server,
/// `tool:<toolName>` for a tool) so it works uniformly for all of them —
/// exactly the "for EVERY: PROVIDER, MODEL, ENDPOINT, DEPLOYMENT ... TOOL,
/// MCP SERVER" requirement.
class CircuitBreakerRegistry {
  CircuitBreakerRegistry({CircuitBreakerConfig? defaultConfig})
      : _defaultConfig = defaultConfig ?? const CircuitBreakerConfig();

  final CircuitBreakerConfig _defaultConfig;
  final Map<String, CircuitBreaker> _breakers = {};

  CircuitBreaker breakerFor(String id, {CircuitBreakerConfig? config}) {
    return _breakers.putIfAbsent(id, () => CircuitBreaker(id, config: config ?? _defaultConfig));
  }

  CircuitBreaker? existing(String id) => _breakers[id];

  List<CircuitBreaker> get all => _breakers.values.toList(growable: false);

  /// Given a set of candidate ids (e.g. every model in a capability tier),
  /// returns those that are currently available, ranked by health score —
  /// the ranking `ModelRouter` consults for failover ordering.
  List<CircuitBreaker> rankAvailable(Iterable<String> candidateIds) {
    final candidates = candidateIds
        .map((id) => breakerFor(id))
        .where((b) => b.isAvailable)
        .toList();
    candidates.sort((a, b) => b.healthScore.compareTo(a.healthScore));
    return candidates;
  }

  void resetAll() {
    for (final breaker in _breakers.values) {
      breaker.manualClose();
      breaker.resetStatistics();
    }
  }
}
