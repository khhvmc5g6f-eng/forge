import 'package:forge/core/models/chat_types.dart';
import 'package:forge/core/models/model_capabilities.dart';
import 'package:forge/core/models/model_provider.dart';

/// A scripted [ModelProvider] for tests: returns queued responses in order,
/// records every request it received, and never touches the network.
class FakeModelProvider implements ModelProvider {
  FakeModelProvider(this._providerId, {List<ChatCompletionResult>? responses})
      : _responses = responses ?? [];

  final String _providerId;
  final List<ChatCompletionResult> _responses;
  final List<ChatRequest> receivedRequests = [];
  int _cursor = 0;
  List<ModelDescriptor> descriptors = const [];
  bool healthy = true;

  @override
  String get providerId => _providerId;

  void enqueue(ChatCompletionResult response) => _responses.add(response);

  /// Queues a failure: the next `chat` call throws [error] instead of
  /// returning a response. Consumes one slot, like [enqueue].
  void enqueueError([Object? error]) =>
      _errors.add(error ?? ModelProviderException('scripted failure'));

  final List<Object> _errors = [];

  @override
  Future<ChatCompletionResult> chat(String modelName, ChatRequest request) async {
    receivedRequests.add(request);
    if (_errors.isNotEmpty) {
      throw _errors.removeAt(0);
    }
    if (_cursor >= _responses.length) {
      throw StateError('FakeModelProvider($_providerId) ran out of scripted responses.');
    }
    return _responses[_cursor++];
  }

  @override
  Stream<ChatStreamChunk> streamChat(String modelName, ChatRequest request) {
    throw UnimplementedError('streamChat not used in these tests');
  }

  @override
  Future<List<ModelDescriptor>> listModels() async => descriptors;

  @override
  Future<bool> healthCheck() async => healthy;
}

ChatCompletionResult textResponse(String content) => ChatCompletionResult(
      message: ChatMessage.assistant(content),
      finishReason: FinishReason.stop,
    );

ChatCompletionResult toolCallResponse(String toolName, Map<String, dynamic> args, {String id = 'call_1'}) =>
    ChatCompletionResult(
      message: ChatMessage.assistant('', toolCalls: [
        ToolCallRequest(id: id, name: toolName, arguments: args),
      ]),
      finishReason: FinishReason.toolCalls,
    );

ModelDescriptor descriptorFor(
  String providerId,
  String modelName, {
  ModelCapabilities capabilities = const ModelCapabilities(supportsToolCalling: true, isFree: true),
}) =>
    ModelDescriptor(
      id: ModelId(providerId: providerId, modelName: modelName),
      capabilities: capabilities,
    );
