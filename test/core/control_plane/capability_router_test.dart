import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/control_plane/capability_router.dart';
import 'package:forge/core/control_plane/circuit_breaker.dart';
import 'package:forge/core/control_plane/circuit_breaker_registry.dart';
import 'package:forge/core/control_plane/model_tier.dart';
import 'package:forge/core/models/chat_types.dart';
import 'package:forge/core/models/model_capabilities.dart';
import 'package:forge/core/models/model_provider.dart';
import 'package:forge/core/models/model_registry.dart';
import 'package:forge/core/models/task_classifier.dart';

class _OneShotProvider implements ModelProvider {
  _OneShotProvider(this.descriptor);
  final ModelDescriptor descriptor;
  @override
  String get providerId => descriptor.id.providerId;
  @override
  Future<List<ModelDescriptor>> listModels() async => [descriptor];
  @override
  Future<bool> healthCheck() async => true;
  @override
  Future<ChatCompletionResult> chat(String modelName, ChatRequest request) =>
      throw UnimplementedError();
  @override
  Stream<ChatStreamChunk> streamChat(String modelName, ChatRequest request) =>
      throw UnimplementedError();
}

Future<void> seed(ModelRegistry registry, ModelId id, ModelCapabilities caps) =>
    registry.refreshFromProvider(_OneShotProvider(ModelDescriptor(id: id, capabilities: caps)));

void main() {
  late ModelRegistry modelRegistry;
  late TierRegistry tierRegistry;
  late CircuitBreakerRegistry circuitBreakers;
  late CapabilityRouter router;

  setUp(() {
    modelRegistry = ModelRegistry();
    tierRegistry = TierRegistry();
    circuitBreakers = CircuitBreakerRegistry(
      defaultConfig: const CircuitBreakerConfig(consecutiveFailuresToDegrade: 1, consecutiveFailuresToOpen: 1),
    );
    router = CapabilityRouter(modelRegistry: modelRegistry, tierRegistry: tierRegistry, circuitBreakers: circuitBreakers);
  });

  test('TierRegistry.recomputeFromRegistry assigns tiers from composite reliability', () async {
    final strong = ModelId(providerId: 'nvidia-nim', modelName: 'kimi-k3');
    await seed(modelRegistry, strong, const ModelCapabilities(supportsToolCalling: true));
    for (var i = 0; i < 10; i++) {
      modelRegistry.recordUsageResult(strong, succeeded: true, latencyMs: 100);
    }
    modelRegistry.recordArenaScores(strong, codingReliability: 0.95, reasoningReliability: 0.9, toolReliability: 0.9);

    tierRegistry.recomputeFromRegistry(modelRegistry);
    expect(tierRegistry.tierFor(strong), ModelTier.s);
  });

  test('a local model is always assigned ModelTier.local regardless of score', () async {
    final local = ModelId(providerId: 'ollama', modelName: 'llama3');
    await seed(modelRegistry, local, const ModelCapabilities(isLocal: true, isFree: true));
    tierRegistry.recomputeFromRegistry(modelRegistry);
    expect(tierRegistry.tierFor(local), ModelTier.local);
  });

  test('a pinned model is not overwritten by recomputeFromRegistry', () async {
    final model = ModelId(providerId: 'nvidia-nim', modelName: 'pinned-model');
    await seed(modelRegistry, model, const ModelCapabilities(supportsToolCalling: true));
    tierRegistry.assign(model, ModelTier.s, reason: 'manual pin', pin: true);
    for (var i = 0; i < 10; i++) {
      modelRegistry.recordUsageResult(model, succeeded: false, latencyMs: 100);
    }
    modelRegistry.recordArenaScores(model, codingReliability: 0.1);
    tierRegistry.recomputeFromRegistry(modelRegistry);
    expect(tierRegistry.tierFor(model), ModelTier.s); // still pinned
  });

  test('select() skips a model whose circuit is OPEN and picks the next healthy candidate', () async {
    final broken = ModelId(providerId: 'nvidia-nim', modelName: 'broken');
    final healthy = ModelId(providerId: 'groq', modelName: 'healthy');
    await seed(modelRegistry, broken, const ModelCapabilities(supportsToolCalling: true, contextWindowTokens: 100000));
    await seed(modelRegistry, healthy, const ModelCapabilities(supportsToolCalling: true, contextWindowTokens: 100000));
    tierRegistry.assign(broken, ModelTier.a);
    tierRegistry.assign(healthy, ModelTier.a);

    circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(broken)).recordFailure(CircuitFailureType.serverError);
    expect(circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(broken)).state, CircuitState.open);

    final selected = router.select(ModelTier.a, TaskCategory.complexCode);
    expect(selected.id, healthy);
  });

  test('a provider-level circuit outage excludes all of that provider\'s models', () async {
    final nvidiaModel = ModelId(providerId: 'nvidia-nim', modelName: 'model-x');
    final groqModel = ModelId(providerId: 'groq', modelName: 'model-y');
    await seed(modelRegistry, nvidiaModel, const ModelCapabilities(supportsToolCalling: true));
    await seed(modelRegistry, groqModel, const ModelCapabilities(supportsToolCalling: true));
    tierRegistry.assign(nvidiaModel, ModelTier.c);
    tierRegistry.assign(groqModel, ModelTier.c);

    circuitBreakers.breakerFor('nvidia-nim').recordFailure(CircuitFailureType.rateLimited); // provider-level

    final selected = router.select(ModelTier.c, TaskCategory.simpleCode);
    expect(selected.id, groqModel);
  });

  test('vision requirement is preserved during failover — a non-vision model is never substituted', () async {
    final visionModel = ModelId(providerId: 'nvidia-nim', modelName: 'vision-model');
    final textOnlyModel = ModelId(providerId: 'groq', modelName: 'text-only');
    await seed(modelRegistry, visionModel, const ModelCapabilities(supportsToolCalling: true, supportsVision: true));
    await seed(modelRegistry, textOnlyModel, const ModelCapabilities(supportsToolCalling: true, supportsVision: false));
    tierRegistry.assign(visionModel, ModelTier.a);
    tierRegistry.assign(textOnlyModel, ModelTier.a);

    circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(visionModel)).recordFailure(CircuitFailureType.serverError);

    expect(
      () => router.select(ModelTier.a, TaskCategory.vision),
      throwsA(isA<NoHealthyModelForTierException>()),
    );
  });

  test('failoverChain returns every healthy candidate ranked, not just the first', () async {
    final a = ModelId(providerId: 'nvidia-nim', modelName: 'a');
    final b = ModelId(providerId: 'groq', modelName: 'b');
    final c = ModelId(providerId: 'cerebras', modelName: 'c');
    for (final id in [a, b, c]) {
      await seed(modelRegistry, id, const ModelCapabilities(supportsToolCalling: true));
      tierRegistry.assign(id, ModelTier.b);
    }
    final chain = router.failoverChain(ModelTier.b, TaskCategory.simpleCode);
    expect(chain.map((m) => m.id), containsAll([a, b, c]));
  });
}
