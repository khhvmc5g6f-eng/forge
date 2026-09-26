import 'model_provider.dart';
import 'model_registry.dart';
import 'task_classifier.dart';

/// User-selectable global routing policy, per the brief:
/// AUTO / FREE ONLY / LOCAL ONLY / NVIDIA ONLY / MANUAL.
enum RoutingPolicy { auto, freeOnly, localOnly, nvidiaOnly, manual }

class NoSuitableModelException implements Exception {
  NoSuitableModelException(this.category, this.policy);
  final TaskCategory category;
  final RoutingPolicy policy;

  @override
  String toString() =>
      'No model satisfies task category $category under policy $policy';
}

/// Selects the best available model for a task. Default policy per the
/// brief: use the strongest suitable FREE configured model first, escalate
/// only when necessary — "necessary" meaning the free candidate pool is
/// empty, unavailable, or below the reliability floor for tasks that
/// [TaskRequirements.preferHighReliability].
/// Checks whether a circuit (keyed the same way
/// `CapabilityRouter.providerCircuitId`/`modelCircuitId` key theirs) is
/// currently available. Declared here as a bare function type — rather than
/// importing `CircuitBreakerRegistry` from `core/control_plane/` — so this
/// file never depends on the control-plane layer that itself depends on
/// `core/models/` (avoiding an import cycle); callers wire the real registry
/// in via a one-line closure, e.g.
/// `(id) => circuitBreakerRegistry.breakerFor(id).isAvailable`.
typedef CircuitAvailabilityCheck = bool Function(String circuitId);

class ModelRouter {
  ModelRouter({
    required this.registry,
    this.policy = RoutingPolicy.auto,
    this.manualModelId,
    this.minReliabilityForCriticalTasks = 0.6,
    this.isCircuitAvailable,
  });

  final ModelRegistry registry;
  RoutingPolicy policy;

  /// When set, models whose provider or model-specific circuit is not
  /// available (i.e. `OPEN`) are excluded from selection entirely — the
  /// Control Plane extension's integration point. `null` (the default)
  /// preserves this router's original behaviour for callers that don't use
  /// the circuit breaker subsystem.
  CircuitAvailabilityCheck? isCircuitAvailable;

  /// Required when [policy] is [RoutingPolicy.manual].
  ModelId? manualModelId;

  /// Below this coding-reliability score, a model is excluded from
  /// consideration for tasks marked [TaskRequirements.preferHighReliability]
  /// once it has a statistically meaningful run count (see
  /// [_meaningfulSampleSize]). New/untested models are never excluded by
  /// this floor — they simply rank lower than proven ones.
  final double minReliabilityForCriticalTasks;

  static const int _meaningfulSampleSize = 5;

  RegisteredModel selectModel(TaskCategory category) {
    final requirements = TaskRequirements.byCategory[category]!;

    if (policy == RoutingPolicy.manual) {
      final id = manualModelId;
      if (id == null) {
        throw NoSuitableModelException(category, policy);
      }
      final model = registry.get(id);
      if (model == null) throw NoSuitableModelException(category, policy);
      return model;
    }

    var candidates = registry.all.where((m) => m.available).where((model) {
      final caps = model.capabilities;
      if (requirements.requiresToolCalling && !caps.supportsToolCalling) {
        return false;
      }
      if (requirements.requiresVision && !caps.supportsVision) return false;
      if (caps.contextWindowTokens < requirements.minContextWindowTokens) {
        return false;
      }
      final circuitCheck = isCircuitAvailable;
      if (circuitCheck != null) {
        if (!circuitCheck(model.id.providerId) || !circuitCheck(model.id.key)) return false;
      }
      return true;
    });

    switch (policy) {
      case RoutingPolicy.localOnly:
        candidates = candidates.where((m) => m.capabilities.isLocal);
        break;
      case RoutingPolicy.nvidiaOnly:
        candidates = candidates.where((m) => m.id.providerId == 'nvidia-nim');
        break;
      case RoutingPolicy.freeOnly:
        candidates = candidates.where((m) => m.capabilities.isFree);
        break;
      case RoutingPolicy.auto:
      case RoutingPolicy.manual:
        break;
    }

    var pool = candidates.toList();
    if (pool.isEmpty) throw NoSuitableModelException(category, policy);

    if (requirements.preferHighReliability) {
      final proven = pool.where((m) =>
          m.performance.totalRuns >= _meaningfulSampleSize &&
          m.performance.codingReliability < minReliabilityForCriticalTasks);
      pool = pool.where((m) => !proven.contains(m)).toList();
      if (pool.isEmpty) throw NoSuitableModelException(category, policy);
    }

    // Default policy: strongest suitable FREE model first, escalate to paid
    // only when necessary (no viable free candidate at this stage).
    if (policy == RoutingPolicy.auto) {
      final free = pool.where((m) => m.capabilities.isFree).toList();
      if (free.isNotEmpty) {
        pool = free;
      }
    }

    pool.sort((a, b) => _score(b, requirements).compareTo(_score(a, requirements)));
    return pool.first;
  }

  double _score(RegisteredModel model, TaskRequirements requirements) {
    final perf = model.performance;
    double score = 0;
    score += perf.codingReliability * 3;
    score += perf.toolReliability * 2;
    if (requirements.requiresReasoning) {
      score += perf.reasoningReliability * 3;
    }
    // Untested models (totalRuns == 0) get a small neutral boost over
    // *known-bad* ones but rank below anything proven reliable, so the
    // router still explores new models without preferring the unknown over
    // the demonstrated.
    if (perf.totalRuns == 0) score += 1.0;
    // Latency penalty, normalised so it never dominates reliability.
    if (perf.averageLatencyMs > 0) {
      score -= (perf.averageLatencyMs / 10000).clamp(0, 2);
    }
    return score;
  }
}
