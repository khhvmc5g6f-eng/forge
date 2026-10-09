import 'dart:convert';
import 'dart:io';

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
  CircuitBreakerRegistry({CircuitBreakerConfig? defaultConfig, this.persistencePath})
      : _defaultConfig = defaultConfig ?? const CircuitBreakerConfig();

  final CircuitBreakerConfig _defaultConfig;

  /// Optional JSON file the registry persists circuit state to. When set,
  /// every state *transition* (never a plain success/failure tally — those
  /// would write on every request) saves the full circuit map so
  /// availability signals survive a control-plane restart; [loadFromDisk]
  /// restores them. The schema matches the `circuits.json` the desktop
  /// control plane already writes:
  /// `{"version":1,"circuits":[...],"savedAt":...}`.
  final String? persistencePath;
  final Map<String, CircuitBreaker> _breakers = {};

  CircuitBreaker breakerFor(String id, {CircuitBreakerConfig? config}) {
    return _breakers.putIfAbsent(
      id,
      () => CircuitBreaker(
        id,
        config: config ?? _defaultConfig,
        // Transition-driven persistence: the hook fires only on state
        // transitions, so this can never become a per-request disk write.
        onStateChange: persistencePath == null ? null : (_) => saveToDisk(),
      ),
    );
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

  /// Writes every circuit's state to [persistencePath]. Called by each
  /// breaker's `onStateChange` hook (see [breakerFor]) and best-effort: an
  /// unwritable path must never take the control plane itself down.
  void saveToDisk() {
    final path = persistencePath;
    if (path == null) return;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'circuits': [for (final b in _breakers.values) b.toJson()],
          'savedAt': DateTime.now().millisecondsSinceEpoch,
        }),
        flush: true,
      );
    } catch (_) {
      // Best-effort persistence: ignore write failures entirely.
    }
  }

  /// Restores circuits previously written by [saveToDisk] into this
  /// registry (creating breakers via [breakerFor] so configs follow the
  /// normal rules). A missing or malformed file leaves the registry
  /// untouched — corrupt persistence must never brick routing.
  void loadFromDisk() {
    final path = persistencePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return;
      final circuits = decoded['circuits'];
      if (circuits is! List) return;
      for (final entry in circuits) {
        if (entry is! Map<String, dynamic>) continue;
        final id = entry['id'];
        if (id is! String) continue;
        breakerFor(id).restoreFromJson(entry);
      }
    } catch (_) {
      // Unreadable/corrupt file: start clean rather than crashing.
    }
  }

  void resetAll() {
    for (final breaker in _breakers.values) {
      breaker.manualClose();
      breaker.resetStatistics();
    }
  }
}
