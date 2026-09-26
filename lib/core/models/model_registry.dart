import 'model_capabilities.dart';
import 'model_provider.dart';

/// A model tracked by the registry: static capabilities plus empirically
/// observed performance. This is the data backing the "NVIDIA Model
/// Registry" table in the brief (available / coding / reasoning / agentic /
/// tool use / vision / context / latency / success / failure / rate limit /
/// free status / last tested).
class RegisteredModel {
  RegisteredModel({
    required this.id,
    required this.capabilities,
    this.performance = const ModelPerformanceRecord(),
    this.available = true,
  });

  final ModelId id;
  ModelCapabilities capabilities;
  ModelPerformanceRecord performance;
  bool available;
}

/// Central catalogue of every model across every configured provider. The
/// [ModelProvider]s populate it via [refreshFromProvider]; the Model Arena
/// and live usage update [RegisteredModel.performance] via
/// [recordUsageResult] / [recordArenaScores].
class ModelRegistry {
  final Map<String, RegisteredModel> _models = {};

  List<RegisteredModel> get all => _models.values.toList(growable: false);

  RegisteredModel? get(ModelId id) => _models[id.key];

  Future<void> refreshFromProvider(ModelProvider provider) async {
    List<ModelDescriptor> descriptors;
    try {
      descriptors = await provider.listModels();
    } catch (_) {
      // Provider unreachable: mark any previously known models from this
      // provider as unavailable rather than dropping their history.
      for (final model in _models.values) {
        if (model.id.providerId == provider.providerId) {
          model.available = false;
        }
      }
      return;
    }
    for (final descriptor in descriptors) {
      final existing = _models[descriptor.id.key];
      if (existing == null) {
        _models[descriptor.id.key] = RegisteredModel(
          id: descriptor.id,
          capabilities: descriptor.capabilities,
        );
      } else {
        existing.capabilities = descriptor.capabilities;
        existing.available = true;
      }
    }
  }

  void recordUsageResult(
    ModelId id, {
    required bool succeeded,
    required int latencyMs,
    bool rateLimited = false,
  }) {
    final model = _models[id.key];
    if (model == null) return;
    model.performance = model.performance.withResult(
      succeeded: succeeded,
      latencyMs: latencyMs,
      rateLimited: rateLimited,
    );
  }

  void recordArenaScores(
    ModelId id, {
    double? codingReliability,
    double? toolReliability,
    double? reasoningReliability,
  }) {
    final model = _models[id.key];
    if (model == null) return;
    model.performance = model.performance.withArenaScores(
      codingReliability: codingReliability,
      toolReliability: toolReliability,
      reasoningReliability: reasoningReliability,
    );
  }

  List<RegisteredModel> byProvider(String providerId) =>
      _models.values.where((m) => m.id.providerId == providerId).toList();
}
