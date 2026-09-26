import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../security/secrets_store.dart';
import '../chat_types.dart';
import '../model_capabilities.dart';
import '../model_provider.dart';

/// Base adapter for any provider speaking the OpenAI `/v1/chat/completions`
/// + `/v1/models` wire format: NVIDIA NIM, Ollama, LM Studio, vLLM, and
/// OpenAI itself. Only base URL, auth header, and a few response quirks
/// differ between these — see the subclasses in this directory.
///
/// The [http.Client] is injected so tests exercise real request/response
/// parsing logic against a fake transport, without a network call.
class OpenAiCompatibleProvider implements ModelProvider {
  OpenAiCompatibleProvider({
    required this.config,
    required this._secretsStore,
    http.Client? httpClient,
    this.maxRetries = 3,
  })  : _http = httpClient ?? http.Client();

  @override
  String get providerId => config.providerId;

  final ProviderConfig config;
  final SecretsStore _secretsStore;
  final http.Client _http;
  final int maxRetries;

  Future<Map<String, String>> _headers() async {
    final headers = {
      'Content-Type': 'application/json',
      ...config.defaultHeaders,
    };
    final ref = config.apiKeySecretRef;
    if (ref != null) {
      final key = await _secretsStore.read(ref);
      if (key != null && key.isNotEmpty) {
        headers['Authorization'] = 'Bearer $key';
      }
    }
    return headers;
  }

  Uri _endpoint(String path) => config.baseUrl.resolve(path);

  @override
  Future<List<ModelDescriptor>> listModels() async {
    final headers = await _headers();
    final response = await _withRetry(() => _http.get(
          _endpoint('models'),
          headers: headers,
        ));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = (body['data'] as List<dynamic>? ?? const []);
    return data.map((entry) {
      final map = entry as Map<String, dynamic>;
      final id = map['id'] as String;
      return ModelDescriptor(
        id: ModelId(providerId: providerId, modelName: id),
        capabilities: capabilitiesFor(id, map),
      );
    }).toList(growable: false);
  }

  /// Hook for subclasses to refine capability inference from a `/v1/models`
  /// entry. The base implementation returns conservative defaults since the
  /// OpenAI-compatible spec does not standardise capability fields.
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return const ModelCapabilities();
  }

  @override
  Future<bool> healthCheck() async {
    try {
      await listModels();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ChatCompletionResult> chat(String modelName, ChatRequest request) async {
    final payload = _buildPayload(modelName, request, stream: false);
    final headers = await _headers();
    final response = await _withRetry(() => _http.post(
          _endpoint('chat/completions'),
          headers: headers,
          body: jsonEncode(payload),
        ));
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseCompletion(body);
  }

  @override
  Stream<ChatStreamChunk> streamChat(String modelName, ChatRequest request) async* {
    final payload = _buildPayload(modelName, request, stream: true);
    final req = http.Request('POST', _endpoint('chat/completions'));
    req.headers.addAll(await _headers());
    req.body = jsonEncode(payload);
    final streamedResponse = await _http.send(req);
    if (streamedResponse.statusCode >= 400) {
      final body = await streamedResponse.stream.bytesToString();
      throw _errorFor(streamedResponse.statusCode, body);
    }
    final lines = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') return;
      if (data.isEmpty) continue;
      final chunk = jsonDecode(data) as Map<String, dynamic>;
      yield _parseStreamChunk(chunk);
    }
  }

  Map<String, dynamic> _buildPayload(
    String modelName,
    ChatRequest request, {
    required bool stream,
  }) {
    return {
      'model': modelName,
      'stream': stream,
      'messages': request.messages.map(_encodeMessage).toList(),
      if (request.tools.isNotEmpty)
        'tools': request.tools
            .map((t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.parametersSchema,
                  },
                })
            .toList(),
      if (request.temperature != null) 'temperature': request.temperature,
      if (request.maxOutputTokens != null)
        'max_tokens': request.maxOutputTokens,
    };
  }

  Map<String, dynamic> _encodeMessage(ChatMessage message) {
    switch (message.role) {
      case ChatRole.system:
        return {'role': 'system', 'content': message.content};
      case ChatRole.user:
        return {'role': 'user', 'content': message.content};
      case ChatRole.assistant:
        return {
          'role': 'assistant',
          'content': message.content,
          if (message.toolCalls.isNotEmpty)
            'tool_calls': message.toolCalls
                .map((c) => {
                      'id': c.id,
                      'type': 'function',
                      'function': {
                        'name': c.name,
                        'arguments': jsonEncode(c.arguments),
                      },
                    })
                .toList(),
        };
      case ChatRole.tool:
        final result = message.toolResult!;
        return {
          'role': 'tool',
          'tool_call_id': result.toolCallId,
          'content': result.content,
        };
    }
  }

  ChatCompletionResult _parseCompletion(Map<String, dynamic> body) {
    final choice = (body['choices'] as List).first as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>;
    final content = message['content'] as String? ?? '';
    final toolCallsRaw = message['tool_calls'] as List<dynamic>?;
    final toolCalls = <ToolCallRequest>[];
    if (toolCallsRaw != null) {
      for (final entry in toolCallsRaw) {
        final map = entry as Map<String, dynamic>;
        final function = map['function'] as Map<String, dynamic>;
        Map<String, dynamic> args;
        try {
          args = jsonDecode(function['arguments'] as String) as Map<String, dynamic>;
        } catch (_) {
          args = <String, dynamic>{};
        }
        toolCalls.add(ToolCallRequest(
          id: map['id'] as String,
          name: function['name'] as String,
          arguments: args,
        ));
      }
    }
    final usageRaw = body['usage'] as Map<String, dynamic>?;
    final usage = usageRaw == null
        ? const TokenUsage.zero()
        : TokenUsage(
            promptTokens: (usageRaw['prompt_tokens'] as num?)?.toInt() ?? 0,
            completionTokens:
                (usageRaw['completion_tokens'] as num?)?.toInt() ?? 0,
            cachedPromptTokens: (usageRaw['prompt_tokens_details']
                        as Map<String, dynamic>?)?['cached_tokens']
                    as int? ??
                0,
          );
    return ChatCompletionResult(
      message: ChatMessage.assistant(content, toolCalls: toolCalls),
      finishReason: _finishReasonFrom(choice['finish_reason'] as String?),
      usage: usage,
      raw: body,
    );
  }

  ChatStreamChunk _parseStreamChunk(Map<String, dynamic> chunk) {
    final choices = chunk['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return const ChatStreamChunk();
    }
    final choice = choices.first as Map<String, dynamic>;
    final delta = choice['delta'] as Map<String, dynamic>? ?? const {};
    final content = delta['content'] as String? ?? '';
    final finish = choice['finish_reason'] as String?;
    return ChatStreamChunk(
      deltaContent: content,
      finishReason: finish == null ? null : _finishReasonFrom(finish),
    );
  }

  FinishReason _finishReasonFrom(String? raw) {
    switch (raw) {
      case 'tool_calls':
        return FinishReason.toolCalls;
      case 'length':
        return FinishReason.length;
      case 'content_filter':
        return FinishReason.contentFilter;
      case 'stop':
        return FinishReason.stop;
      default:
        return FinishReason.stop;
    }
  }

  Future<http.Response> _withRetry(Future<http.Response> Function() send) async {
    var attempt = 0;
    while (true) {
      attempt++;
      http.Response response;
      try {
        response = await send().timeout(config.timeout);
      } on TimeoutException {
        if (attempt >= maxRetries) {
          throw ModelProviderException('Request timed out', retryable: true);
        }
        await Future.delayed(_backoff(attempt));
        continue;
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        if (attempt >= maxRetries) {
          throw _errorFor(response.statusCode, response.body);
        }
        await Future.delayed(_backoff(attempt));
        continue;
      }
      if (response.statusCode >= 400) {
        throw _errorFor(response.statusCode, response.body);
      }
      return response;
    }
  }

  Duration _backoff(int attempt) => Duration(milliseconds: 250 * (1 << attempt));

  ModelProviderException _errorFor(int statusCode, String body) {
    return ModelProviderException(
      'HTTP $statusCode from $providerId: $body',
      statusCode: statusCode,
      rateLimited: statusCode == 429,
      retryable: statusCode == 429 || statusCode >= 500,
    );
  }
}
