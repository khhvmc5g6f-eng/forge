import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/control_plane/capability_router.dart';
import 'package:forge/core/control_plane/circuit_breaker.dart';
import 'package:forge/core/control_plane/circuit_breaker_registry.dart';
import 'package:forge/core/control_plane/model_tier.dart';
import 'package:forge/core/control_plane/supervisor_engine.dart';
import 'package:forge/core/control_plane/task_graph.dart';
import 'package:forge/core/models/chat_types.dart';
import 'package:forge/core/models/model_capabilities.dart';
import 'package:forge/core/models/model_provider.dart';
import 'package:forge/core/models/model_registry.dart';
import 'package:forge/core/models/task_classifier.dart';
import 'package:forge/core/tools/policy_engine.dart';
import 'package:forge/core/tools/tool.dart';
import 'package:forge/core/tools/tool_category.dart';

import '../../support/fake_model_provider.dart';

ToolGateway newGateway() => ToolGateway(
      policyEngine: PolicyEngine(
        mode: OperatingMode.autonomous,
        grantedLevel: PermissionLevel.runBuildTest,
        projectRoot: '/repo',
      ),
    );

TaskGraphNode node(String id, {List<String> dependsOn = const [], ModelTier tier = ModelTier.b}) {
  return TaskGraphNode(
    contract: TaskContract(
      id: id,
      objective: 'do $id',
      scope: 'repo',
      tier: tier,
      taskCategory: TaskCategory.simpleCode,
    ),
    dependsOn: dependsOn,
  );
}

void main() {
  late ModelRegistry modelRegistry;
  late TierRegistry tierRegistry;
  late CircuitBreakerRegistry circuitBreakers;
  late CapabilityRouter capabilityRouter;

  setUp(() {
    modelRegistry = ModelRegistry();
    tierRegistry = TierRegistry();
    circuitBreakers = CircuitBreakerRegistry(
      defaultConfig: const CircuitBreakerConfig(consecutiveFailuresToDegrade: 1, consecutiveFailuresToOpen: 1),
    );
    capabilityRouter = CapabilityRouter(modelRegistry: modelRegistry, tierRegistry: tierRegistry, circuitBreakers: circuitBreakers);
  });

  Future<void> registerModel(ModelId id) async {
    await modelRegistry.refreshFromProvider(_OneShotProvider(id));
    tierRegistry.assign(id, ModelTier.b);
  }

  test('TaskGraph.readyNodes only returns nodes whose dependencies are done', () {
    final graph = TaskGraph(masterObjective: 'investigate');
    graph.addNode(node('a'));
    graph.addNode(node('b', dependsOn: ['a']));
    expect(graph.readyNodes.map((n) => n.contract.id), ['a']);

    graph.nodes['a']!.status = GraphNodeStatus.done;
    expect(graph.readyNodes.map((n) => n.contract.id), ['b']);
  });

  test('independent nodes with no dependencies are both ready for parallel dispatch', () {
    final graph = TaskGraph(masterObjective: 'investigate');
    graph.addNode(node('logs'));
    graph.addNode(node('git'));
    graph.addNode(node('tests'));
    expect(graph.readyNodes, hasLength(3));
  });

  test('a successful node produces a parsed WorkerResult and records circuit success', () async {
    final modelId = ModelId(providerId: 'nvidia-nim', modelName: 'worker-model');
    await registerModel(modelId);
    final provider = FakeModelProvider('nvidia-nim');
    provider.enqueue(textResponse('RESULT: done\nEVIDENCE: ran the check\nCONFIDENCE: 90\nNEXT ACTION: none'));

    final graph = TaskGraph(masterObjective: 'x');
    final n = node('a');
    graph.addNode(n);

    final engine = SupervisorEngine(
      graph: graph,
      capabilityRouter: capabilityRouter,
      circuitBreakers: circuitBreakers,
      modelRegistry: modelRegistry,
      resolveProvider: (_) => provider,
      gatewayFor: (_) => newGateway(),
    );

    await engine.runNode(n);
    expect(n.status, GraphNodeStatus.done);
    expect(n.result!.confidence, closeTo(0.9, 0.01));
    expect(circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(modelId)).state, CircuitState.closed);
  });

  test('a node fails over to the next healthy model in the same tier after an infra failure', () async {
    final broken = ModelId(providerId: 'nvidia-nim', modelName: 'broken');
    final healthy = ModelId(providerId: 'groq', modelName: 'healthy');
    await registerModel(broken);
    await registerModel(healthy);

    final brokenProvider = FakeModelProvider('nvidia-nim');
    brokenProvider.healthy = false; // not used directly, just clarity
    final healthyProvider = FakeModelProvider('groq');
    healthyProvider.enqueue(textResponse('RESULT: fixed\nEVIDENCE: e\nCONFIDENCE: 80'));

    final graph = TaskGraph(masterObjective: 'x');
    final n = node('a');
    graph.addNode(n);

    final engine = SupervisorEngine(
      graph: graph,
      capabilityRouter: capabilityRouter,
      circuitBreakers: circuitBreakers,
      modelRegistry: modelRegistry,
      resolveProvider: (providerId) => providerId == 'nvidia-nim' ? brokenProvider : healthyProvider,
      gatewayFor: (_) => newGateway(),
    );

    await engine.runNode(n);

    expect(n.status, GraphNodeStatus.done);
    expect(n.modelsAttempted, [broken.key, healthy.key]);
    expect(circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(broken)).totalFailures, 1);
  });

  test('a node that exhausts every candidate in its tier fails', () async {
    final onlyModel = ModelId(providerId: 'nvidia-nim', modelName: 'only');
    await registerModel(onlyModel);
    final provider = FakeModelProvider('nvidia-nim'); // no queued responses -> throws StateError each attempt

    final graph = TaskGraph(masterObjective: 'x');
    final n = node('a');
    graph.addNode(n);

    final engine = SupervisorEngine(
      graph: graph,
      capabilityRouter: capabilityRouter,
      circuitBreakers: circuitBreakers,
      modelRegistry: modelRegistry,
      resolveProvider: (_) => provider,
      gatewayFor: (_) => newGateway(),
      maxAttemptsPerNode: 2,
    );

    await engine.runNode(n);
    expect(n.status, GraphNodeStatus.failed);
  });

  test('low-confidence results are marked done but flagged for escalation', () async {
    final modelId = ModelId(providerId: 'nvidia-nim', modelName: 'uncertain-model');
    await registerModel(modelId);
    final provider = FakeModelProvider('nvidia-nim');
    provider.enqueue(textResponse('RESULT: maybe\nEVIDENCE: weak\nCONFIDENCE: 20'));

    final graph = TaskGraph(masterObjective: 'x');
    final n = node('a');
    graph.addNode(n);

    final engine = SupervisorEngine(
      graph: graph,
      capabilityRouter: capabilityRouter,
      circuitBreakers: circuitBreakers,
      modelRegistry: modelRegistry,
      resolveProvider: (_) => provider,
      gatewayFor: (_) => newGateway(),
    );

    await engine.runNode(n);
    expect(n.status, GraphNodeStatus.done);
    expect(n.failureReason, contains('low confidence'));
  });

  test('reconcile() prefers higher confidence and records a conflict, never averages', () {
    final graph = TaskGraph(masterObjective: 'x');
    final a = node('a')..result = const WorkerResult(resultText: 'test passes', evidence: 'ran locally', confidence: 0.6);
    final b = node('b')..result = const WorkerResult(resultText: 'test fails', evidence: 'ran locally differently', confidence: 0.9);
    graph.addNode(a);
    graph.addNode(b);

    final engine = SupervisorEngine(
      graph: graph,
      capabilityRouter: capabilityRouter,
      circuitBreakers: circuitBreakers,
      modelRegistry: modelRegistry,
      resolveProvider: (_) => FakeModelProvider('x'),
      gatewayFor: (_) => newGateway(),
    );

    final resolved = engine.reconcile(a, b);
    expect(resolved.resultText, 'test fails');
    expect(graph.conflicts, isNotEmpty);
  });

  test('reconcile() trusts identical deterministic evidence over confidence alone', () {
    final graph = TaskGraph(masterObjective: 'x');
    final a = node('a')..result = const WorkerResult(resultText: 'passes', evidence: 'flutter test exit 0', confidence: 0.3);
    final b = node('b')..result = const WorkerResult(resultText: 'fails', evidence: 'flutter test exit 0', confidence: 0.95);
    graph.addNode(a);
    graph.addNode(b);

    final engine = SupervisorEngine(
      graph: graph,
      capabilityRouter: capabilityRouter,
      circuitBreakers: circuitBreakers,
      modelRegistry: modelRegistry,
      resolveProvider: (_) => FakeModelProvider('x'),
      gatewayFor: (_) => newGateway(),
    );

    final resolved = engine.reconcile(a, b);
    expect(resolved.resultText, 'passes'); // identical evidence -> first result wins, not the louder one
  });

  test('runToCompletion dispatches dependency chains in the correct order', () async {
    final modelId = ModelId(providerId: 'nvidia-nim', modelName: 'worker');
    await registerModel(modelId);
    final provider = FakeModelProvider('nvidia-nim');
    provider
      ..enqueue(textResponse('RESULT: a done\nCONFIDENCE: 90'))
      ..enqueue(textResponse('RESULT: b done\nCONFIDENCE: 90'));

    final graph = TaskGraph(masterObjective: 'x');
    graph.addNode(node('a'));
    graph.addNode(node('b', dependsOn: ['a']));

    final engine = SupervisorEngine(
      graph: graph,
      capabilityRouter: capabilityRouter,
      circuitBreakers: circuitBreakers,
      modelRegistry: modelRegistry,
      resolveProvider: (_) => provider,
      gatewayFor: (_) => newGateway(),
    );

    await engine.runToCompletion();
    expect(graph.isComplete, isTrue);
    expect(graph.nodes['a']!.status, GraphNodeStatus.done);
    expect(graph.nodes['b']!.status, GraphNodeStatus.done);
  });
}

class _OneShotProvider implements ModelProvider {
  _OneShotProvider(this.id);
  final ModelId id;
  @override
  String get providerId => id.providerId;
  @override
  Future<List<ModelDescriptor>> listModels() async => [
        ModelDescriptor(
          id: id,
          capabilities: const ModelCapabilities(supportsToolCalling: true, isFree: true),
        ),
      ];
  @override
  Future<bool> healthCheck() async => true;
  @override
  Future<ChatCompletionResult> chat(String modelName, ChatRequest request) =>
      throw UnimplementedError();
  @override
  Stream<ChatStreamChunk> streamChat(String modelName, ChatRequest request) =>
      throw UnimplementedError();
}
