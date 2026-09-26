import '../models/model_provider.dart';
import '../models/model_registry.dart';
import '../models/model_router.dart';
import '../models/task_classifier.dart';
import 'circuit_breaker_registry.dart';
import 'model_tier.dart';

class NoHealthyModelForTierException implements Exception {
  NoHealthyModelForTierException(this.tier, this.category);
  final ModelTier tier;
  final TaskCategory category;
  @override
  String toString() =>
      'No healthy, capable model is currently assigned to tier ${tier.name} for $category.';
}

/// Sits above the plain [ModelRouter] in the spec's layering
/// (`TASK ROUTER -> MODEL CAPABILITY ROUTER -> SUPERVISOR/WORKER LOGIC ->
/// PROVIDER GATEWAY`): given a required [ModelTier] and [TaskCategory], it
/// returns the healthiest capable model — filtering out anything whose
/// circuit is `OPEN`, and, critically, **never relaxing task requirements to
/// find a candidate** ("If a vision model fails, fail over to another VISION
/// model... Failover must preserve task requirements").
class CapabilityRouter {
  CapabilityRouter({
    required this.modelRegistry,
    required this.tierRegistry,
    required this.circuitBreakers,
    this.policy = RoutingPolicy.auto,
  });

  final ModelRegistry modelRegistry;
  final TierRegistry tierRegistry;
  final CircuitBreakerRegistry circuitBreakers;
  RoutingPolicy policy;

  /// The circuit id convention used throughout the control plane: a
  /// provider-level circuit (`nvidia`) and a model-level circuit
  /// (`nvidia::kimi-k3`) are tracked independently — a single bad model on a
  /// healthy provider shouldn't take the whole provider offline, and vice
  /// versa a provider outage should be visible even if one of its models
  /// happens not to have failed yet.
  static String providerCircuitId(String providerId) => providerId;
  static String modelCircuitId(ModelId id) => id.key;

  List<RegisteredModel> _eligibleModels(ModelTier tier, TaskRequirements requirements) {
    return modelRegistry.all.where((model) {
      if (!model.available) return false;
      final effectiveTier = tierRegistry.tierFor(model.id) ?? _fallbackTier(model);
      if (effectiveTier != tier) return false;
      final caps = model.capabilities;
      if (requirements.requiresToolCalling && !caps.supportsToolCalling) return false;
      if (requirements.requiresVision && !caps.supportsVision) return false;
      if (caps.contextWindowTokens < requirements.minContextWindowTokens) return false;
      switch (policy) {
        case RoutingPolicy.localOnly:
          if (!caps.isLocal) return false;
        case RoutingPolicy.freeOnly:
          if (!caps.isFree) return false;
        case RoutingPolicy.nvidiaOnly:
          if (model.id.providerId != 'nvidia-nim') return false;
        case RoutingPolicy.auto:
        case RoutingPolicy.manual:
          break;
      }
      return true;
    }).toList();
  }

  ModelTier _fallbackTier(RegisteredModel model) =>
      model.capabilities.isLocal ? ModelTier.local : ModelTier.b;

  /// Ranks eligible models by circuit health first (an unhealthy provider
  /// never outranks a healthy one, regardless of raw reliability score),
  /// then by the same reliability scoring `ModelRouter` uses.
  List<RegisteredModel> _rankedHealthy(List<RegisteredModel> eligible) {
    final withHealth = eligible.where((model) {
      final providerHealthy = circuitBreakers.breakerFor(providerCircuitId(model.id.providerId)).isAvailable;
      final modelHealthy = circuitBreakers.breakerFor(modelCircuitId(model.id)).isAvailable;
      return providerHealthy && modelHealthy;
    }).toList();

    withHealth.sort((a, b) {
      final healthA = circuitBreakers.breakerFor(modelCircuitId(a.id)).healthScore;
      final healthB = circuitBreakers.breakerFor(modelCircuitId(b.id)).healthScore;
      if (healthA != healthB) return healthB.compareTo(healthA);
      return b.performance.codingReliability.compareTo(a.performance.codingReliability);
    });
    return withHealth;
  }

  /// Selects the single best model for [tier]/[category]. Throws
  /// [NoHealthyModelForTierException] if nothing eligible is currently
  /// healthy — callers (the Supervisor/Orchestrator) are expected to widen
  /// the search via [failoverChain] or escalate/pause rather than silently
  /// relaxing requirements.
  RegisteredModel select(ModelTier tier, TaskCategory category) {
    final requirements = TaskRequirements.byCategory[category]!;
    final ranked = _rankedHealthy(_eligibleModels(tier, requirements));
    if (ranked.isEmpty) throw NoHealthyModelForTierException(tier, category);
    return ranked.first;
  }

  /// The full ordered failover chain for [tier]/[category] — every
  /// currently-healthy, requirement-preserving candidate, best first. The
  /// Orchestrator walks this list on failure rather than "just picking the
  /// next model" arbitrarily.
  List<RegisteredModel> failoverChain(ModelTier tier, TaskCategory category) {
    final requirements = TaskRequirements.byCategory[category]!;
    return _rankedHealthy(_eligibleModels(tier, requirements));
  }
}
