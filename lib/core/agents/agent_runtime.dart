import '../models/chat_types.dart';
import '../models/model_provider.dart';
import '../models/model_registry.dart';
import '../observability/telemetry.dart';
import '../security/untrusted_content.dart';
import '../tools/tool.dart';
import 'agent_role.dart';

/// One step of the transparent event stream the brief requires ("Provide a
/// transparent event stream... Show actions and evidence. Do not expose
/// private model chain-of-thought.").
class AgentEvent {
  AgentEvent(this.agentId, this.role, this.message, {DateTime? at}) : at = at ?? DateTime.now();
  final String agentId;
  final AgentRole role;
  final String message;
  final DateTime at;

  @override
  String toString() =>
      '${at.toIso8601String().substring(11, 19)} [${role.name}] $message';
}

typedef AgentEventSink = void Function(AgentEvent event);

class AgentReport {
  const AgentReport({
    required this.agentId,
    required this.role,
    required this.finalMessage,
    required this.toolResults,
    required this.iterations,
    required this.usage,
  });

  final String agentId;
  final AgentRole role;
  final String finalMessage;
  final List<UntrustedContent> toolResults;
  final int iterations;
  final TokenUsage usage;
}

class AgentRuntimeException implements Exception {
  AgentRuntimeException(this.message);
  final String message;
  @override
  String toString() => 'AgentRuntimeException: $message';
}

/// The single ReAct loop shared by every specialist role — the brief is
/// explicit that "Agents should be roles sharing infrastructure rather than
/// 20 copies of an LLM." An [AgentDefinition] parameterises the loop; the
/// loop itself (call model → run any tool calls → feed results back → repeat
/// until [FinishReason.stop] or [AgentDefinition.maxIterations]) is written
/// exactly once here.
class AgentRuntime {
  AgentRuntime({
    required this.agentId,
    required this.definition,
    required this.provider,
    required this.modelName,
    required this.gateway,
    required this.registry,
    this.onEvent,
    this.telemetry,
    this.parentAgentId,
  });

  final String agentId;
  final AgentDefinition definition;
  final ModelProvider provider;
  final String modelName;
  final ToolGateway gateway;
  final ModelRegistry registry;
  final AgentEventSink? onEvent;

  /// Optional Neural Observatory instrumentation. When null (the default —
  /// every pre-existing constructor call), the runtime behaves exactly as
  /// before; when wired, the runtime reports agent/model/tool events with
  /// real measured latencies and provider-reported token counts.
  final AgentTelemetry? telemetry;

  /// The delegating agent's id when this runtime is a subagent — the
  /// execution-graph edge. Null for top-level agents.
  final String? parentAgentId;

  void _emit(String message) => onEvent?.call(AgentEvent(agentId, definition.role, message));

  List<ToolSpec> _availableTools() {
    return gateway.registeredTools
        .where((t) => definition.allowedToolCategories.contains(t.category))
        .map((t) => ToolSpec(
              name: t.name,
              description: t.description,
              parametersSchema: t.parametersSchema,
            ))
        .toList();
  }

  Future<AgentReport> run(String taskPrompt) async {
    final tools = _availableTools();
    final messages = <ChatMessage>[
      ChatMessage.system(definition.systemPrompt),
      ChatMessage.user(taskPrompt),
    ];
    final toolResults = <UntrustedContent>[];
    var usage = const TokenUsage.zero();

    _emit('started: $taskPrompt');
    telemetry?.agentStarted(
      agentId: agentId,
      role: definition.role.name,
      parentAgentId: parentAgentId,
    );

    for (var iteration = 0; iteration < definition.maxIterations; iteration++) {
      final modelId = ModelId(providerId: provider.providerId, modelName: modelName);
      final started = DateTime.now();
      ChatCompletionResult result;
      try {
        result = await provider.chat(
          modelName,
          ChatRequest(messages: messages, tools: tools),
        );
      } catch (e) {
        registry.recordUsageResult(
          modelId,
          succeeded: false,
          latencyMs: DateTime.now().difference(started).inMilliseconds,
          rateLimited: e is ModelProviderException && e.rateLimited,
        );
        telemetry?.modelRequest(
          agentId: agentId,
          role: definition.role.name,
          providerId: provider.providerId,
          modelName: modelName,
          latencyMs: DateTime.now().difference(started).inMilliseconds,
          succeeded: false,
          rateLimited: e is ModelProviderException && e.rateLimited,
          promptTokens: 0,
          completionTokens: 0,
          cachedPromptTokens: 0,
        );
        _emit('model call failed: $e');
        rethrow;
      }
      registry.recordUsageResult(
        modelId,
        succeeded: true,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
      );
      telemetry?.modelRequest(
        agentId: agentId,
        role: definition.role.name,
        providerId: provider.providerId,
        modelName: modelName,
        latencyMs: DateTime.now().difference(started).inMilliseconds,
        succeeded: true,
        promptTokens: result.usage.promptTokens,
        completionTokens: result.usage.completionTokens,
        cachedPromptTokens: result.usage.cachedPromptTokens,
      );
      usage += result.usage;
      messages.add(result.message);

      if (result.finishReason != FinishReason.toolCalls ||
          result.message.toolCalls.isEmpty) {
        _emit('completed after ${iteration + 1} iteration(s)');
        telemetry?.agentFinished(
          agentId: agentId,
          role: definition.role.name,
          status: 'ok',
          iterations: iteration + 1,
          promptTokens: usage.promptTokens,
          completionTokens: usage.completionTokens,
          cachedPromptTokens: usage.cachedPromptTokens,
        );
        return AgentReport(
          agentId: agentId,
          role: definition.role,
          finalMessage: result.message.content,
          toolResults: toolResults,
          iterations: iteration + 1,
          usage: usage,
        );
      }

      for (final call in result.message.toolCalls) {
        _emit('tool call: ${call.name}(${call.arguments})');
        UntrustedContent content;
        var isError = false;
        final toolWatch = Stopwatch()..start();
        try {
          content = await gateway.invoke(call.name, call.arguments);
        } catch (e) {
          isError = true;
          content = UntrustedContent(
            source: ContentSource.toolResult,
            body: 'ERROR: $e',
          );
        } finally {
          telemetry?.toolCall(
            agentId: agentId,
            role: definition.role.name,
            toolName: call.name,
            durationMs: toolWatch.elapsedMilliseconds,
            succeeded: !isError,
            decision: isError ? 'error' : 'allow',
          );
        }
        toolResults.add(content);
        _emit('tool result (${call.name}): ${_truncate(content.body)}');
        messages.add(ChatMessage.toolResult(ToolResultMessage(
          toolCallId: call.id,
          content: content.body,
          isError: isError,
        )));
      }
    }

    telemetry?.agentFinished(
      agentId: agentId,
      role: definition.role.name,
      status: 'error',
      iterations: definition.maxIterations,
      promptTokens: usage.promptTokens,
      completionTokens: usage.completionTokens,
      cachedPromptTokens: usage.cachedPromptTokens,
    );
    throw AgentRuntimeException(
      'Agent ${definition.role.name} exceeded ${definition.maxIterations} iterations without completing.',
    );
  }

  String _truncate(String s) => s.length <= 300 ? s : '${s.substring(0, 300)}…';
}
