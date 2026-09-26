/// Provider-agnostic chat/tool-calling types shared by every [ModelProvider]
/// adapter. Concrete adapters translate to/from their wire format at the
/// edge; nothing above this layer should know whether a message is destined
/// for an OpenAI-compatible endpoint or the Anthropic Messages API.
library;

import 'package:meta/meta.dart';

enum ChatRole { system, user, assistant, tool }

/// A single tool invocation the model asked to perform.
@immutable
class ToolCallRequest {
  const ToolCallRequest({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;

  /// Decoded JSON arguments. Adapters are responsible for parsing the raw
  /// wire format (which may be a JSON string, as in OpenAI-compatible APIs)
  /// into this map before it reaches the rest of the system.
  final Map<String, dynamic> arguments;
}

/// The result of executing a [ToolCallRequest], fed back to the model.
@immutable
class ToolResultMessage {
  const ToolResultMessage({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });

  final String toolCallId;
  final String content;
  final bool isError;
}

@immutable
class ChatMessage {
  const ChatMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const [],
    this.toolResult,
    this.name,
  });

  const ChatMessage.system(String content)
      : this(role: ChatRole.system, content: content);

  const ChatMessage.user(String content)
      : this(role: ChatRole.user, content: content);

  const ChatMessage.assistant(String content, {List<ToolCallRequest> toolCalls = const []})
      : this(role: ChatRole.assistant, content: content, toolCalls: toolCalls);

  const ChatMessage.toolResult(ToolResultMessage result)
      : this(role: ChatRole.tool, toolResult: result);

  final ChatRole role;
  final String content;
  final List<ToolCallRequest> toolCalls;
  final ToolResultMessage? toolResult;

  /// Optional tool/function name, used by some wire formats for tool-role
  /// messages.
  final String? name;
}

/// A tool exposed to the model, in provider-agnostic JSON-Schema form.
@immutable
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parametersSchema,
  });

  final String name;
  final String description;

  /// A JSON Schema object (as a Dart map) describing the tool's parameters.
  final Map<String, dynamic> parametersSchema;
}

enum FinishReason { stop, toolCalls, length, contentFilter, error }

@immutable
class ChatCompletionResult {
  const ChatCompletionResult({
    required this.message,
    required this.finishReason,
    this.usage = const TokenUsage.zero(),
    this.raw,
  });

  final ChatMessage message;
  final FinishReason finishReason;
  final TokenUsage usage;

  /// The raw decoded provider response, retained for diagnostics/telemetry.
  final Map<String, dynamic>? raw;
}

@immutable
class TokenUsage {
  const TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    this.cachedPromptTokens = 0,
  });

  const TokenUsage.zero()
      : promptTokens = 0,
        completionTokens = 0,
        cachedPromptTokens = 0;

  final int promptTokens;
  final int completionTokens;
  final int cachedPromptTokens;

  int get totalTokens => promptTokens + completionTokens;

  TokenUsage operator +(TokenUsage other) => TokenUsage(
        promptTokens: promptTokens + other.promptTokens,
        completionTokens: completionTokens + other.completionTokens,
        cachedPromptTokens: cachedPromptTokens + other.cachedPromptTokens,
      );
}

/// A single chunk of a streamed completion.
@immutable
class ChatStreamChunk {
  const ChatStreamChunk({
    this.deltaContent = '',
    this.deltaToolCalls = const [],
    this.finishReason,
    this.usage,
  });

  final String deltaContent;
  final List<ToolCallRequest> deltaToolCalls;
  final FinishReason? finishReason;
  final TokenUsage? usage;
}

@immutable
class ChatRequest {
  const ChatRequest({
    required this.messages,
    this.tools = const [],
    this.temperature,
    this.maxOutputTokens,
    this.reasoningEffort,
  });

  final List<ChatMessage> messages;
  final List<ToolSpec> tools;
  final double? temperature;
  final int? maxOutputTokens;

  /// Provider-specific reasoning-effort hint (e.g. "low"/"medium"/"high"),
  /// ignored by providers/models that don't support it.
  final String? reasoningEffort;
}
