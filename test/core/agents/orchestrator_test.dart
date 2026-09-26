import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/agents/agent_role.dart';
import 'package:forge/core/agents/orchestrator.dart';
import 'package:forge/core/models/model_capabilities.dart';
import 'package:forge/core/models/model_registry.dart';
import 'package:forge/core/models/model_router.dart';
import 'package:forge/core/security/untrusted_content.dart';
import 'package:forge/core/tools/policy_engine.dart';
import 'package:forge/core/tools/tool.dart';
import 'package:forge/core/tools/tool_category.dart';

import '../../support/fake_model_provider.dart';

void main() {
  late ModelRegistry registry;
  late FakeModelProvider provider;
  late ModelRouter router;

  setUp(() async {
    registry = ModelRegistry();
    provider = FakeModelProvider('nvidia-nim');
    provider.descriptors = [
      descriptorFor('nvidia-nim', 'test-model',
          capabilities: const ModelCapabilities(
            supportsToolCalling: true,
            isFree: true,
            contextWindowTokens: 128000,
          )),
    ];
    await registry.refreshFromProvider(provider);
    router = ModelRouter(registry: registry);
  });

  ToolGateway newGateway() => ToolGateway(
        policyEngine: PolicyEngine(
          mode: OperatingMode.autonomous,
          grantedLevel: PermissionLevel.runBuildTest,
          projectRoot: '/repo',
        ),
      );

  AgentOrchestrator newOrchestrator({SubagentBudget? budget}) => AgentOrchestrator(
        registry: registry,
        router: router,
        resolveProvider: (_) => provider,
        gatewayFor: (_) => newGateway(),
        budget: budget ?? const SubagentBudget(),
      );

  test('spawn returns a report once the model stops requesting tools', () async {
    provider.enqueue(textResponse('done investigating'));
    final orchestrator = newOrchestrator();
    final report = await orchestrator.spawn(
      const SubagentRequest(role: AgentRole.repository, prompt: 'find the bug'),
    );
    expect(report.finalMessage, 'done investigating');
    expect(orchestrator.totalSpawned, 1);
  });

  test('refuses to spawn beyond the configured max depth', () async {
    final orchestrator = newOrchestrator(budget: const SubagentBudget(maxDepth: 1));
    expect(
      () => orchestrator.spawn(
        const SubagentRequest(role: AgentRole.repository, prompt: 'x'),
        depth: 2,
      ),
      throwsA(isA<SubagentBudgetExceededException>()),
    );
  });

  test('refuses to spawn beyond the total agent budget', () async {
    provider.enqueue(textResponse('a'));
    final orchestrator = newOrchestrator(budget: const SubagentBudget(maxTotalAgents: 1));
    await orchestrator.spawn(const SubagentRequest(role: AgentRole.repository, prompt: 'first'));
    expect(
      () => orchestrator.spawn(const SubagentRequest(role: AgentRole.repository, prompt: 'second')),
      throwsA(isA<SubagentBudgetExceededException>()),
    );
  });

  test('cancel() prevents any further spawns', () async {
    final orchestrator = newOrchestrator();
    orchestrator.cancel();
    expect(
      () => orchestrator.spawn(const SubagentRequest(role: AgentRole.repository, prompt: 'x')),
      throwsA(isA<SubagentBudgetExceededException>()),
    );
  });

  test('spawnParallel respects maxConcurrency by batching', () async {
    provider
      ..enqueue(textResponse('r1'))
      ..enqueue(textResponse('r2'))
      ..enqueue(textResponse('r3'));
    final orchestrator = newOrchestrator(budget: const SubagentBudget(maxConcurrency: 2));
    final reports = await orchestrator.spawnParallel([
      const SubagentRequest(role: AgentRole.repository, prompt: 'a'),
      const SubagentRequest(role: AgentRole.repository, prompt: 'b'),
      const SubagentRequest(role: AgentRole.repository, prompt: 'c'),
    ]);
    expect(reports.map((r) => r.finalMessage), containsAll(['r1', 'r2', 'r3']));
  });

  test('agent runtime executes a tool call before finishing', () async {
    provider
      ..enqueue(toolCallResponse('list_directory', {'path': '/repo'}))
      ..enqueue(textResponse('found it'));

    final gateway = newGateway();
    gateway.register(_FakeListDirectoryTool());
    final orchestrator = AgentOrchestrator(
      registry: registry,
      router: router,
      resolveProvider: (_) => provider,
      gatewayFor: (_) => gateway,
    );
    final report = await orchestrator.spawn(
      const SubagentRequest(role: AgentRole.repository, prompt: 'list files'),
    );
    expect(report.finalMessage, 'found it');
    expect(report.toolResults, hasLength(1));
    expect(report.toolResults.first.body, contains('main.dart'));
  });
}

class _FakeListDirectoryTool implements Tool {
  @override
  String get name => 'list_directory';
  @override
  ToolCategory get category => ToolCategory.filesystem;
  @override
  String get description => 'fake';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object', 'properties': {}};
  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) => ToolInvocation(
        category: category,
        toolName: name,
        targetPath: arguments['path'] as String?,
        explicitLevel: PermissionLevel.observe,
      );
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async => const UntrustedContent(
        source: ContentSource.fileContent,
        body: 'main.dart\npubspec.yaml',
      );
}
