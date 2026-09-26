import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../security/secrets_store.dart';
import '../chat_types.dart';
import '../model_capabilities.dart';
import '../model_provider.dart';

/// Anthropic's Messages API is not OpenAI-wire-compatible (distinct
/// system-prompt placement, `tool_use`/`tool_result` content blocks, no
/// `/v1/models` discovery endpoint at all), so it gets its own adapter
/// rather than reusing [OpenAiCompatibleProvider]. Used both as an ordinary
/// [ModelProvider] and — more commonly in Forge — as the pluggable Final
/// Reviewer (see core/review/reviewer.dart).
class AnthropicProvider implements ModelProvider {
  AnthropicProvider({
    required this._secretsStore,
    Uri? baseUrl,
    this._apiKeySecretRef = 'anthropic_api_key',
    http.Client? httpClient,
    this.apiVersion = '2023-06-01',
    this.maxRetries = 3,
  })  : _baseUrl = baseUrl ?? Uri.parse('https://api.anthropic.com/v1/'),
        _http = httpClient ?? http.Client();

  @override
  String get providerId => 'anthropic';

  final SecretsStore _secretsStore;
  final Uri _baseUrl;
  final String _apiKeySecretRef;
  final http.Client _http;
  final String apiVersion;
  final int maxRetries;

  /// Anthropic has no `/v1/models` list-and-discover-capabilities endpoint
  /// analogous to the OpenAI-compatible providers; the current model family
  /// is declared statically and kept current by hand, matching how the rest
  /// of Forge treats "current NVIDIA APIs rather than assuming one model
  /// forever" — this table is the single place to update on a new release.
  static const List<String> knownModelIds = [
    'claude-opus-5-5',
    'claude-sonnet-5',
    'claude-fable-5-1',
    'claude-haiku-4-5-20251001',
  ];

  @override
  Future<List<ModelDescriptor>> listModels() async {
    return knownModelIds
        .map((id) => ModelDescriptor(
              id: ModelId(providerId: providerId, modelName: id),
              capabilities: const ModelCapabilities(
                supportsToolCalling: true,
                supportsVision: true,
                supportsReasoningEffort: true,
                contextWindowTokens: 200000,
                maxOutputTokens: 8192,
                isFree: false,
              ),
            ))
        .toList(growable: false);
  }

  @override
  Future<bool> healthCheck() async {
    try {
      final headers = await _headers();
      final response = await _http.get(_baseUrl.resolve('models'), headers: headers);
      return response.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> _headers() async {
    final key = await _secretsStore.read(_apiKeySecretRef);
    return {
      'Content-Type': 'application/json',
      'anthropic-version': apiVersion,
      'x-api-key': ?key,
    };
  }

  @override
  Future<ChatCompletionResult> chat(String modelName, ChatRequest request) async {
    final headers = await _headers();
    final response = await _send(() => _http.post(
          _baseUrl.resolve('messages'),
          headers: headers,
          body: jsonEncode(_buildPayload(modelName, request, stream: false)),
        ));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseCompletion(body);
  }

  @override
  Stream<ChatStreamChunk> streamChat(String modelName, ChatRequest request) async* {
    final headers = await _headers();
    final req = http.Request('POST', _baseUrl.resolve('messages'));
    req.headers.addAll(headers);
    req.body = jsonEncode(_buildPayload(modelName, request, stream: true));
    final streamed = await _http.send(req);
    if (streamed.statusCode >= 400) {
      final body = await streamed.stream.bytesToString();
      throw ModelProviderException(
        'HTTP ${streamed.statusCode} from anthropic: $body',
        statusCode: streamed.statusCode,
        rateLimited: streamed.statusCode == 429,
        retryable: streamed.statusCode == 429 || streamed.statusCode >= 500,
      );
    }
    final lines = streamed.stream.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      final event = jsonDecode(data) as Map<String, dynamic>;
      final type = event['type'] as String?;
      if (type == 'content_block_delta') {
        final delta = event['delta'] as Map<String, dynamic>;
        yield ChatStreamChunk(deltaContent: delta['text'] as String? ?? '');
      } else if (type == 'message_delta') {
        final stopReason = (event['delta'] as Map<String, dynamic>)['stop_reason'] as String?;
        if (stopReason != null) {
          yield ChatStreamChunk(finishReason: _finishReasonFrom(stopReason));
        }
      }
    }
  }

  Map<String, dynamic> _buildPayload(
    String modelName,
    ChatRequest request, {
    required bool stream,
  }) {
    final systemParts = request.messages
        .where((m) => m.role == ChatRole.system)
        .map((m) => m.content)
        .join('\n\n');
    final nonSystem = request.messages.where((m) => m.role != ChatRole.system);
    return {
      'model': modelName,
      'stream': stream,
      'max_tokens': request.maxOutputTokens ?? 4096,
      if (systemParts.isNotEmpty) 'system': systemParts,
      'messages': nonSystem.map(_encodeMessage).toList(),
      if (request.tools.isNotEmpty)
        'tools': request.tools
            .map((t) => {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.parametersSchema,
                })
            .toList(),
      if (request.temperature != null) 'temperature': request.temperature,
    };
  }

  Map<String, dynamic> _encodeMessage(ChatMessage message) {
    if (message.role == ChatRole.tool) {
      final result = message.toolResult!;
      return {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': result.toolCallId,
            'content': result.content,
            'is_error': result.isError,
          }
        ],
      };
    }
    if (message.toolCalls.isNotEmpty) {
      return {
        'role': 'assistant',
        'content': [
          if (message.content.isNotEmpty) {'type': 'text', 'text': message.content},
          ...message.toolCalls.map((c) => {
                'type': 'tool_use',
                'id': c.id,
                'name': c.name,
                'input': c.arguments,
              }),
        ],
      };
    }
    return {
      'role': message.role == ChatRole.assistant ? 'assistant' : 'user',
      'content': message.content,
    };
  }

  ChatCompletionResult _parseCompletion(Map<String, dynamic> body) {
    final content = body['content'] as List<dynamic>? ?? const [];
    final textBuffer = StringBuffer();
    final toolCalls = <ToolCallRequest>[];
    for (final block in content) {
      final map = block as Map<String, dynamic>;
      if (map['type'] == 'text') {
        textBuffer.write(map['text'] as String? ?? '');
      } else if (map['type'] == 'tool_use') {
        toolCalls.add(ToolCallRequest(
          id: map['id'] as String,
          name: map['name'] as String,
          arguments: (map['input'] as Map<String, dynamic>?) ?? const {},
        ));
      }
    }
    final usageRaw = body['usage'] as Map<String, dynamic>?;
    final usage = usageRaw == null
        ? const TokenUsage.zero()
        : TokenUsage(
            promptTokens: (usageRaw['input_tokens'] as num?)?.toInt() ?? 0,
            completionTokens: (usageRaw['output_tokens'] as num?)?.toInt() ?? 0,
            cachedPromptTokens:
                (usageRaw['cache_read_input_tokens'] as num?)?.toInt() ?? 0,
          );
    return ChatCompletionResult(
      message: ChatMessage.assistant(textBuffer.toString(), toolCalls: toolCalls),
      finishReason: _finishReasonFrom(body['stop_reason'] as String?),
      usage: usage,
      raw: body,
    );
  }

  FinishReason _finishReasonFrom(String? raw) {
    switch (raw) {
      case 'tool_use':
        return FinishReason.toolCalls;
      case 'max_tokens':
        return FinishReason.length;
      case 'end_turn':
      case 'stop_sequence':
        return FinishReason.stop;
      default:
        return FinishReason.stop;
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() send) async {
    var attempt = 0;
    while (true) {
      attempt++;
      final response = await send();
      if ((response.statusCode == 429 || response.statusCode >= 500) &&
          attempt < maxRetries) {
        await Future.delayed(Duration(milliseconds: 250 * (1 << attempt)));
        continue;
      }
      if (response.statusCode >= 400) {
        throw ModelProviderException(
          'HTTP ${response.statusCode} from anthropic: ${response.body}',
          statusCode: response.statusCode,
          rateLimited: response.statusCode == 429,
          retryable: response.statusCode == 429 || response.statusCode >= 500,
        );
      }
      return response;
    }
  }
}
