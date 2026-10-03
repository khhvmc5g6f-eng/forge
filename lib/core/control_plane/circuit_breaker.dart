// DEPRECATED (TD-004): the Forge control plane lives in the TypeScript engine
// (sdk/packages/forge/src/circuit.ts: three-level provider/key/model breakers). The Flutter UI no longer uses this; it is a client of the engine
// (lib/core/forge_engine). Nothing here is deleted yet because the standalone
// Dart CLI/tests may still reference it; see CONTROL_PLANE.md "Migration to the
// engine" for the removal plan and which parts have no engine equivalent.
// ignore_for_file: deprecated_member_use_from_same_package

/// The five circuit states from the Control Plane spec. `degraded` and
/// `recovering` are both "still usable, but treated with caution" states
/// distinct from the fully-healthy `closed` and fully-unavailable `open`.
enum CircuitState { closed, degraded, open, halfOpen, recovering }

/// Every failure kind the spec lists, tagged with whether it counts as an
/// *infrastructure* failure (which can open a circuit) or not. Model-quality
/// failures (a refusal, a bad tool call, excessive latency) and
/// generated-code failures (a failed build/test attributable to what the
/// model wrote) never open a circuit on their own — per the spec: "Do not
/// treat every application test failure as a provider outage." They still
/// feed `ModelPerformanceRecord`'s quality scoring (see
/// `lib/core/models/model_capabilities.dart`), just not availability.
enum CircuitFailureType {
  rateLimited(isInfrastructure: true),
  serverError(isInfrastructure: true),
  authFailure(isInfrastructure: true),
  timeout(isInfrastructure: true),
  connectionFailure(isInfrastructure: true),
  malformedResponse(isInfrastructure: true),
  quotaExhausted(isInfrastructure: true),
  endpointDisappeared(isInfrastructure: true),
  contextOverflow(isInfrastructure: true),
  hallucinatedToolCall(isInfrastructure: false),
  structuredOutputFailure(isInfrastructure: false),
  modelRefusal(isInfrastructure: false),
  excessiveLatency(isInfrastructure: false),
  incompleteResponse(isInfrastructure: false),
  generatedCodeFailure(isInfrastructure: false);

  const CircuitFailureType({required this.isInfrastructure});
  final bool isInfrastructure;
}

class CircuitBreakerConfig {
  const CircuitBreakerConfig({
    this.consecutiveFailuresToDegrade = 3,
    this.consecutiveFailuresToOpen = 5,
    this.openCooldown = const Duration(seconds: 30),
    this.successesToRecoverFromHalfOpen = 1,
    this.successesToCloseFromRecovering = 3,
    this.successesToCloseFromDegraded = 3,
  });

  final int consecutiveFailuresToDegrade;
  final int consecutiveFailuresToOpen;
  final Duration openCooldown;
  final int successesToRecoverFromHalfOpen;
  final int successesToCloseFromRecovering;
  final int successesToCloseFromDegraded;
}

/// A single named circuit — one per provider, one per (provider, model), one
/// per MCP server, one per tool, wherever the spec calls for isolation. The
/// state machine implements exactly the diagram in the spec:
/// `CLOSED -> DEGRADED -> OPEN -> (cooldown) -> HALF_OPEN -> RECOVERING -> CLOSED`,
/// with any failure during `HALF_OPEN`/`RECOVERING` sending it straight back
/// to `OPEN` rather than lingering in an ambiguous state.
@Deprecated('Use the Forge engine (sdk/packages/forge/src/circuit.ts: three-level provider/key/model breakers) through lib/core/forge_engine. See CONTROL_PLANE.md, Migration to the engine.')
class CircuitBreaker {
  CircuitBreaker(this.id, {CircuitBreakerConfig? config})
      : config = config ?? const CircuitBreakerConfig();

  final String id;
  final CircuitBreakerConfig config;

  CircuitState _state = CircuitState.closed;
  CircuitState get state {
    _maybeTransitionOutOfOpen();
    return _state;
  }

  int _consecutiveInfraFailures = 0;
  int _consecutiveSuccesses = 0;
  DateTime? _openedAt;
  DateTime? _lastFailureAt;

  int totalRequests = 0;
  int totalFailures = 0;
  int total429s = 0;
  int totalTimeouts = 0;
  final List<Duration> _recentLatencies = [];

  DateTime? get lastFailureAt => _lastFailureAt;
  DateTime? get openedAt => _openedAt;

  /// Whether new work should be routed here at all. `open` is the only
  /// state that excludes routing entirely — `degraded`/`recovering`/
  /// `halfOpen` are still usable, just deprioritised (see
  /// `CircuitBreakerRegistry.healthiestOf`).
  bool get isAvailable {
    _maybeTransitionOutOfOpen();
    return _state != CircuitState.open;
  }

  /// A 0.0–1.0 score blending recent success rate and current state, for
  /// display (`NVIDIA 97%`) and for ranking candidates when several circuits
  /// are all technically available.
  double get healthScore {
    if (totalRequests == 0) return 1.0;
    final successRate = 1 - (totalFailures / totalRequests);
    final stateMultiplier = switch (_state) {
      CircuitState.closed => 1.0,
      CircuitState.degraded => 0.7,
      CircuitState.recovering => 0.6,
      CircuitState.halfOpen => 0.3,
      CircuitState.open => 0.0,
    };
    return (successRate * stateMultiplier).clamp(0.0, 1.0);
  }

  Duration get averageLatency {
    if (_recentLatencies.isEmpty) return Duration.zero;
    final totalMs = _recentLatencies.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return Duration(milliseconds: totalMs ~/ _recentLatencies.length);
  }

  void recordSuccess({Duration? latency}) {
    _maybeTransitionOutOfOpen();
    totalRequests++;
    _consecutiveInfraFailures = 0;
    _consecutiveSuccesses++;
    if (latency != null) {
      _recentLatencies.add(latency);
      if (_recentLatencies.length > 50) _recentLatencies.removeAt(0);
    }

    switch (_state) {
      case CircuitState.degraded:
        if (_consecutiveSuccesses >= config.successesToCloseFromDegraded) {
          _state = CircuitState.closed;
          _consecutiveSuccesses = 0;
        }
      case CircuitState.halfOpen:
        if (_consecutiveSuccesses >= config.successesToRecoverFromHalfOpen) {
          _state = CircuitState.recovering;
          _consecutiveSuccesses = 0;
        }
      case CircuitState.recovering:
        if (_consecutiveSuccesses >= config.successesToCloseFromRecovering) {
          _state = CircuitState.closed;
          _consecutiveSuccesses = 0;
        }
      case CircuitState.closed:
      case CircuitState.open:
        break;
    }
  }

  void recordFailure(CircuitFailureType type, {Duration? latency}) {
    _maybeTransitionOutOfOpen();
    totalRequests++;
    totalFailures++;
    _lastFailureAt = DateTime.now();
    _consecutiveSuccesses = 0;
    if (type == CircuitFailureType.rateLimited) total429s++;
    if (type == CircuitFailureType.timeout) totalTimeouts++;
    if (latency != null) {
      _recentLatencies.add(latency);
      if (_recentLatencies.length > 50) _recentLatencies.removeAt(0);
    }

    // Model-quality and generated-code failures never move the circuit
    // toward OPEN — they are a routing/quality signal, not an availability
    // signal. See the spec: "Differentiate INFRASTRUCTURE FAILURE from
    // MODEL QUALITY FAILURE from GENERATED CODE FAILURE."
    if (!type.isInfrastructure) return;

    _consecutiveInfraFailures++;
    switch (_state) {
      case CircuitState.closed:
        if (_consecutiveInfraFailures >= config.consecutiveFailuresToOpen) {
          _open();
        } else if (_consecutiveInfraFailures >= config.consecutiveFailuresToDegrade) {
          _state = CircuitState.degraded;
        }
      case CircuitState.degraded:
        if (_consecutiveInfraFailures >= config.consecutiveFailuresToOpen) _open();
      case CircuitState.halfOpen:
      case CircuitState.recovering:
        // A failure during a probe or during gradual recovery means the
        // provider isn't actually healthy yet — back to OPEN, not a silent
        // demotion to DEGRADED.
        _open();
      case CircuitState.open:
        break;
    }
  }

  void _open() {
    _state = CircuitState.open;
    _openedAt = DateTime.now();
    _consecutiveSuccesses = 0;
  }

  void _maybeTransitionOutOfOpen() {
    if (_state == CircuitState.open &&
        _openedAt != null &&
        DateTime.now().difference(_openedAt!) >= config.openCooldown) {
      _state = CircuitState.halfOpen;
      _consecutiveSuccesses = 0;
    }
  }

  /// Manual override from the Control Centre UI — takes effect immediately
  /// and persists until the user releases it (there is no automatic
  /// transition out of a manually-forced state other than another manual
  /// call, or `resetToHealthy`).
  void manualOpen() {
    _state = CircuitState.open;
    _openedAt = DateTime.now();
  }

  void manualClose() {
    _state = CircuitState.closed;
    _consecutiveInfraFailures = 0;
    _consecutiveSuccesses = 0;
  }

  void resetStatistics() {
    totalRequests = 0;
    totalFailures = 0;
    total429s = 0;
    totalTimeouts = 0;
    _recentLatencies.clear();
  }
}
