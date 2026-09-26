import '../models/model_provider.dart';
import '../models/model_registry.dart';

/// The five tiers from the Control Plane spec. Deliberately **not** an
/// enum-to-model mapping — a tier is a role a model currently fills, derived
/// from measured capability, never a permanent identity. "Models move
/// between tiers according to measured capability."
enum ModelTier {
  s, // Supervisor: architecture, decomposition, reconciliation, review.
  a, // Senior worker: substantial implementation, complex debugging.
  b, // Worker: single files, tests, docs, routine fixes.
  c, // Fast worker: classification, search, summarisation, formatting.
  local, // Local inference: indexing, embeddings, offline work.
}

class TierAssignment {
  const TierAssignment({required this.modelId, required this.tier, required this.assignedAt, required this.reason});

  final ModelId modelId;
  final ModelTier tier;
  final DateTime assignedAt;
  final String reason;
}

/// Tracks which [ModelTier] each model currently fills. Assignments are
/// recomputed from [ModelRegistry]'s empirical `ModelPerformanceRecord`
/// scores (see [recomputeFromRegistry]) rather than fixed at configuration
/// time, and can always be overridden manually (`PIN SUPERVISOR`/`PIN
/// WORKER MODEL` in the Control Centre).
class TierRegistry {
  final Map<String, TierAssignment> _assignments = {};
  final Set<String> _manuallyPinned = {};

  TierAssignment? assignmentFor(ModelId id) => _assignments[id.key];

  ModelTier? tierFor(ModelId id) => _assignments[id.key]?.tier;

  List<ModelId> modelsInTier(ModelTier tier) => _assignments.values
      .where((a) => a.tier == tier)
      .map((a) => a.modelId)
      .toList(growable: false);

  void assign(ModelId id, ModelTier tier, {String reason = 'manual', bool pin = false}) {
    _assignments[id.key] = TierAssignment(
      modelId: id,
      tier: tier,
      assignedAt: DateTime.now(),
      reason: reason,
    );
    if (pin) _manuallyPinned.add(id.key);
  }

  void unpin(ModelId id) => _manuallyPinned.remove(id.key);

  bool isPinned(ModelId id) => _manuallyPinned.contains(id.key);

  /// Re-derives every non-pinned model's tier from its current
  /// [ModelPerformanceRecord]. A model with too few recorded runs
  /// (`< minSampleSize`) keeps whatever assignment it already has (or gets
  /// none) rather than being demoted on noise — matching the router's own
  /// "untested models aren't penalised, just unranked" philosophy
  /// (`lib/core/models/model_router.dart`).
  void recomputeFromRegistry(ModelRegistry registry, {int minSampleSize = 5}) {
    for (final model in registry.all) {
      if (_manuallyPinned.contains(model.id.key)) continue;
      if (model.capabilities.isLocal) {
        assign(model.id, ModelTier.local, reason: 'local inference endpoint');
        continue;
      }
      final perf = model.performance;
      if (perf.totalRuns < minSampleSize) continue;
      final composite =
          (perf.codingReliability + perf.reasoningReliability + perf.toolReliability) / 3;
      final tier = switch (composite) {
        >= 0.85 => ModelTier.s,
        >= 0.70 => ModelTier.a,
        >= 0.50 => ModelTier.b,
        _ => ModelTier.c,
      };
      assign(model.id, tier, reason: 'auto: composite reliability ${composite.toStringAsFixed(2)}');
    }
  }
}
