import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/models/chat_types.dart';
import 'package:forge/core/models/model_capabilities.dart';
import 'package:forge/core/models/model_provider.dart';
import 'package:forge/core/models/model_registry.dart';
import 'package:forge/core/models/model_router.dart';
import 'package:forge/core/models/task_classifier.dart';

void main() {
  group('ModelRouter', () {
    late ModelRegistry registry;

    setUp(() {
      registry = ModelRegistry();
    });

    test('prefers a free model over a paid one for the same task', () async {
      final free = ModelId(providerId: 'nvidia-nim', modelName: 'free-model');
      final paid = ModelId(providerId: 'openai', modelName: 'paid-model');
      await _seed(registry, free, const ModelCapabilities(supportsToolCalling: true, isFree: true));
      await _seed(registry, paid, const ModelCapabilities(supportsToolCalling: true, isFree: false));

      final router = ModelRouter(registry: registry);
      final selected = router.selectModel(TaskCategory.simpleCode);
      expect(selected.id, free);
    });

    test('escalates to paid when no free model is available', () async {
      final paid = ModelId(providerId: 'openai', modelName: 'paid-model');
      await _seed(registry, paid, const ModelCapabilities(supportsToolCalling: true, isFree: false));

      final router = ModelRouter(registry: registry);
      final selected = router.selectModel(TaskCategory.simpleCode);
      expect(selected.id, paid);
    });

    test('excludes models below context window requirement', () async {
      final small = ModelId(providerId: 'p', modelName: 'small');
      await _seed(registry, small,
          const ModelCapabilities(supportsToolCalling: true, isFree: true, contextWindowTokens: 4000));

      final router = ModelRouter(registry: registry);
      expect(
        () => router.selectModel(TaskCategory.architecture),
        throwsA(isA<NoSuitableModelException>()),
      );
    });

    test('localOnly policy excludes remote models even if free', () async {
      final remoteFree = ModelId(providerId: 'nvidia-nim', modelName: 'remote-free');
      final local = ModelId(providerId: 'ollama', modelName: 'local-model');
      await _seed(registry, remoteFree,
          const ModelCapabilities(supportsToolCalling: true, isFree: true, isLocal: false));
      await _seed(registry, local,
          const ModelCapabilities(supportsToolCalling: true, isFree: true, isLocal: true));

      final router = ModelRouter(registry: registry, policy: RoutingPolicy.localOnly);
      final selected = router.selectModel(TaskCategory.simpleCode);
      expect(selected.id, local);
    });

    test('nvidiaOnly policy only considers nvidia-nim provider', () async {
      final nvidia = ModelId(providerId: 'nvidia-nim', modelName: 'nim-model');
      final other = ModelId(providerId: 'openai', modelName: 'gpt');
      await _seed(registry, nvidia, const ModelCapabilities(supportsToolCalling: true, isFree: true));
      await _seed(registry, other, const ModelCapabilities(supportsToolCalling: true, isFree: true));

      final router = ModelRouter(registry: registry, policy: RoutingPolicy.nvidiaOnly);
      final selected = router.selectModel(TaskCategory.simpleCode);
      expect(selected.id, nvidia);
    });

    test('manual policy requires an explicit model id', () {
      final router = ModelRouter(registry: registry, policy: RoutingPolicy.manual);
      expect(
        () => router.selectModel(TaskCategory.simpleCode),
        throwsA(isA<NoSuitableModelException>()),
      );
    });

    test('isCircuitAvailable excludes a model whose circuit is reported unavailable', () async {
      final open = ModelId(providerId: 'nvidia-nim', modelName: 'open-circuit');
      final closed = ModelId(providerId: 'groq', modelName: 'closed-circuit');
      await _seed(registry, open, const ModelCapabilities(supportsToolCalling: true, isFree: true));
      await _seed(registry, closed, const ModelCapabilities(supportsToolCalling: true, isFree: true));

      final router = ModelRouter(
        registry: registry,
        isCircuitAvailable: (id) => id != open.providerId && id != open.key,
      );
      final selected = router.selectModel(TaskCategory.simpleCode);
      expect(selected.id, closed);
    });

    test('excludes a model with proven low reliability for critical tasks', () async {
      final unreliable = ModelId(providerId: 'p', modelName: 'unreliable');
      final reliable = ModelId(providerId: 'p', modelName: 'reliable');
      await _seed(registry, unreliable,
          const ModelCapabilities(supportsToolCalling: true, isFree: true, contextWindowTokens: 100000));
      await _seed(registry, reliable,
          const ModelCapabilities(supportsToolCalling: true, isFree: true, contextWindowTokens: 100000));

      for (var i = 0; i < 6; i++) {
        registry.recordUsageResult(unreliable, succeeded: false, latencyMs: 100);
      }
      registry.recordArenaScores(unreliable, codingReliability: 0.1);
      registry.recordArenaScores(reliable, codingReliability: 0.9);

      final router = ModelRouter(registry: registry);
      final selected = router.selectModel(TaskCategory.architecture);
      expect(selected.id, reliable);
    });
  });
}

Future<void> _seed(ModelRegistry registry, ModelId id, ModelCapabilities capabilities) async {
  final descriptor = ModelDescriptor(id: id, capabilities: capabilities);
  // Seed via the same code path ModelRegistry uses for real providers
  // (refreshFromProvider), rather than reaching into private state.
  await registry.refreshFromProvider(_OneShotProvider([descriptor]));
}

/// Minimal one-shot [ModelProvider] used only to seed [ModelRegistry] via
/// its normal [ModelRegistry.refreshFromProvider] path; `chat`/`streamChat`
/// are never exercised by these router tests.
class _OneShotProvider implements ModelProvider {
  _OneShotProvider(this.descriptors);
  final List<ModelDescriptor> descriptors;

  @override
  String get providerId => descriptors.isEmpty ? 'unknown' : descriptors.first.id.providerId;

  @override
  Future<List<ModelDescriptor>> listModels() async => descriptors;

  @override
  Future<bool> healthCheck() async => true;

  @override
  Future<ChatCompletionResult> chat(String modelName, ChatRequest request) =>
      throw UnimplementedError();

  @override
  Stream<ChatStreamChunk> streamChat(String modelName, ChatRequest request) =>
      throw UnimplementedError();
}
