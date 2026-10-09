import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/agents/agent_role.dart';
import 'package:forge/core/agents/agent_runtime.dart';
import 'package:forge/core/models/chat_types.dart';
import 'package:forge/core/models/model_capabilities.dart';
import 'package:forge/core/models/model_registry.dart';
import 'package:forge/core/observability/observatory_queries.dart';
import 'package:forge/core/observability/observatory_service.dart';
import 'package:forge/core/observability/telemetry_store.dart';
import 'package:forge/core/security/untrusted_content.dart';
import 'package:forge/core/tools/policy_engine.dart';
import 'package:forge/core/tools/tool.dart';
import 'package:forge/core/tools/tool_category.dart';

import '../../support/fake_model_provider.dart';

class _FakeListDirectoryTool implements Tool {
  @override
  String get name => 'list_directory';
  @override
  ToolCategory get category => ToolCategory.filesystem;
  @override
  String get description => 'fake';
  @override
  Map<String, dynamic> get parametersSchema =>
      const {'type': 'object', 'properties': {}};
  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) =>
      ToolInvocation(
        category: category,
        toolName: name,
        targetPath: arguments['path'] as String?,
        explicitLevel: PermissionLevel.observe,
      );
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async =>
      const UntrustedContent(
        source: ContentSource.fileContent,
        body: 'main.dart\npubspec.yaml',
      );
}

void main() {
  late ModelRegistry registry;
  late FakeModelProvider provider;
  late ToolGateway gateway;

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
    gateway = ToolGateway(
      policyEngine: PolicyEngine(
        mode: OperatingMode.autonomous,
        grantedLevel: PermissionLevel.runBuildTest,
        projectRoot: '/repo',
      ),
    );
    gateway.register(_FakeListDirectoryTool());
  });

  /// Runs one instrumented agent that calls a tool then finishes, with
  /// provider-reported token usage on the final response.
  Future<void> runInstrumentedAgent(
    ObservatoryService service,
    String sessionId,
    String agentId,
  ) async {
    provider
      ..enqueue(toolCallResponse('list_directory', {'path': '/repo'}))
      ..enqueue(ChatCompletionResult(
        message: ChatMessage.assistant('done'),
        finishReason: FinishReason.stop,
        usage: const TokenUsage(
          promptTokens: 100,
          completionTokens: 50,
          cachedPromptTokens: 10,
        ),
      ));
    final runtime = AgentRuntime(
      agentId: agentId,
      definition: defaultAgentDefinitions[AgentRole.repository]!,
      provider: provider,
      modelName: 'test-model',
      gateway: gateway,
      registry: registry,
      telemetry: service.telemetryFor(sessionId: sessionId, taskId: 't_1'),
    );
    await runtime.run('list the files');
  }

  test('end-to-end: an instrumented agent run populates real session stats',
      () async {
    final service = ObservatoryService();
    service.noteModel('nvidia-nim', 'test-model', freeTier: true);
    final session = service.beginSession(label: 'integration', taskId: 't_1');

    await runInstrumentedAgent(service, session.id, 'agent_1');
    service.endSession(session.id);

    final stats = service.liveSessionStats(session.id)!;
    expect(stats.requests, 2); // tool-call turn + final turn
    expect(stats.agents, 1);
    expect(stats.toolCalls, 1);
    expect(stats.toolFailures, 0);
    expect(stats.failures, 0);
    expect(stats.errors, 0);
    expect(stats.modelsUsed, ['nvidia-nim::test-model']);
    expect(stats.promptTokens, 100);
    expect(stats.completionTokens, 50);
    expect(stats.cachedTokens, 10);
    expect(stats.latency.count, 2);
    expect(stats.latency.min, greaterThanOrEqualTo(0));
    expect(stats.record.endedAt, isNotNull);
    expect(stats.record.status, 'completed');
    // Free-tier model: cost is a real $0, not an unknown.
    expect(stats.costKnown, isTrue);
    expect(stats.costUsd, 0.0);
    // Context utilisation comes from recorded observations only.
    expect(stats.contextUtilisation, isNull);
  });

  test('the execution graph reflects real parent/child causality', () async {
    final service = ObservatoryService();
    final session = service.beginSession(label: 'trace');
    await runInstrumentedAgent(service, session.id, 'agent_1');

    final trace = service.traceFor(session.id)!;
    // session + agent + 2 model requests + 1 tool call
    expect(trace.nodes, hasLength(5));
    expect(trace.roots.single.id, session.id);
    expect(
      trace.childrenOf('agent_1').map((n) => n.kind.name).toSet(),
      {'model', 'tool'},
    );
    expect(trace.maxFanOut(), 3); // the agent's 2 model requests + 1 tool call

    final breakdown = service.taskBreakdown(session.id);
    final modelRow = breakdown.rows.firstWhere((r) => r.label == 'model');
    expect(modelRow.count, 2);
    expect(modelRow.promptTokens, 100);
    expect(modelRow.completionTokens, 50);
    final toolRow = breakdown.rows.firstWhere((r) => r.label == 'tool');
    expect(toolRow.count, 1);
    expect(breakdown.criticalPath, isNotEmpty);
    expect(breakdown.criticalPath.first.id, session.id);
  });

  test('session intelligence comparison uses measured outcomes', () async {
    final service = ObservatoryService();
    final a = service.beginSession(label: 'same-work');
    await runInstrumentedAgent(service, a.id, 'agent_a');
    final b = service.beginSession(label: 'same-work');
    provider.enqueue(ChatCompletionResult(
      message: ChatMessage.assistant('quick answer'),
      finishReason: FinishReason.stop,
      usage: const TokenUsage(promptTokens: 10, completionTokens: 5),
    ));
    final runtime = AgentRuntime(
      agentId: 'agent_b',
      definition: defaultAgentDefinitions[AgentRole.repository]!,
      provider: provider,
      modelName: 'test-model',
      gateway: gateway,
      registry: registry,
      telemetry: service.telemetryFor(sessionId: b.id),
    );
    await runtime.run('quick question');

    final rows = service.compareSessions([a.id, b.id]);
    expect(rows, hasLength(2));
    expect(rows.first.requests, 2);
    expect(rows.last.requests, 1);
    expect(rows.first.completionTokens, 50);
    expect(rows.last.completionTokens, 5);
  });

  test('network traffic and health index read real counters', () async {
    final service = ObservatoryService();
    service.recordNetworkTraffic(bytesOut: 200, bytesIn: 4000);
    service.recordNetworkTraffic(bytesOut: 100, bytesIn: 1000);

    expect(service.networkBytesOutTotal, 300);
    expect(service.networkBytesInTotal, 5000);
    expect(service.globalNetworkIn.length, 2);

    final health = service.computeHealth();
    // Without request telemetry there is no overall score — honest.
    expect(health.overall, isNull);
    expect(health.coverage, 0.0);

    final session = service.beginSession(label: 'h');
    await runInstrumentedAgent(service, session.id, 'agent_1');
    final withData = service.computeHealth();
    expect(withData.overall, isNotNull);
    expect(withData.coverage, greaterThan(0));
    expect(withData.coverage, lessThan(1)); // network etc. still unmeasured
    final api = withData.components
        .firstWhere((c) => c.component.name == 'apiReliability');
    expect(api.detail, contains('0 failures of 2 requests'));
  });

  test('a latency spike against a noisy baseline raises an alert', () async {
    final service = ObservatoryService();
    final session = service.beginSession(label: 'alerts');
    final telemetry =
        service.telemetryFor(sessionId: session.id, taskId: 't_1');

    const baseline = [98.0, 102, 100, 101, 99, 100, 103, 97, 100];
    for (final latency in baseline) {
      telemetry.modelRequest(
        agentId: 'agent_x',
        role: 'coding',
        providerId: 'p',
        modelName: 'm',
        latencyMs: latency.round(),
        succeeded: true,
        promptTokens: 1,
        completionTokens: 1,
        cachedPromptTokens: 0,
      );
    }
    expect(service.alerts.active, isEmpty);
    telemetry.modelRequest(
      agentId: 'agent_x',
      role: 'coding',
      providerId: 'p',
      modelName: 'm',
      latencyMs: 2000,
      succeeded: true,
      promptTokens: 1,
      completionTokens: 1,
      cachedPromptTokens: 0,
    );
    expect(service.alerts.active, hasLength(1));
    expect(service.alerts.active.single.metric, contains('p::m'));
    expect(service.alerts.active.single.evidence['value'], 2000);
  });

  test('telemetry persists to the JSONL store with quality labels',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('forge_obs_e2e');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final store = JsonlTelemetryStore(tempDir.path, flushThreshold: 5000);

    final service = ObservatoryService(telemetryStore: store);
    service.noteModel('nvidia-nim', 'test-model', freeTier: true);
    final session = service.beginSession(label: 'persist');
    await runInstrumentedAgent(service, session.id, 'agent_1');
    service.endSession(session.id);
    await store.flush();

    final events = await store.readAll();
    final names = events.map((e) => e['name'] as String).toSet();
    expect(names, containsAll([
      'session.begin',
      'agent.start',
      'model.request',
      'tool.call',
      'agent.end',
      'session.end',
    ]));
    final modelSpan = events.firstWhere((e) => e['name'] == 'model.request');
    expect(modelSpan['attributes']['latencyMs.quality'], 'measured');
    expect(modelSpan['attributes']['tokensPerSecond.quality'], 'calculated');
    expect(modelSpan['attributes']['costUsd'], 0.0);
    expect(modelSpan['attributes']['costUsd.quality'], 'calculated');
    expect(store.writeFailures, 0);
  });

  test('runtime with no telemetry behaves exactly as before', () async {
    // The optional hook must be a no-op when unwired — the regression
    // guard for every pre-existing construction site.
    provider
      ..enqueue(toolCallResponse('list_directory', {'path': '/repo'}))
      ..enqueue(textResponse('done'));
    final runtime = AgentRuntime(
      agentId: 'plain',
      definition: defaultAgentDefinitions[AgentRole.repository]!,
      provider: provider,
      modelName: 'test-model',
      gateway: gateway,
      registry: registry,
    );
    final report = await runtime.run('plain run');
    expect(report.finalMessage, 'done');
    expect(report.toolResults, hasLength(1));
  });
}


