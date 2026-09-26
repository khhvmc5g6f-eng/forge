import 'chat_types.dart';
import 'model_capabilities.dart';

/// Identifies a specific model on a specific provider, e.g.
/// (`nvidia-nim`, `meta/llama-3.3-70b-instruct`).
class ModelId {
  const ModelId({required this.providerId, required this.modelName});

  final String providerId;
  final String modelName;

  String get key => '$providerId::$modelName';

  @override
  bool operator ==(Object other) =>
      other is ModelId && other.providerId == providerId && other.modelName == modelName;

  @override
  int get hashCode => Object.hash(providerId, modelName);

  @override
  String toString() => key;
}

/// Configuration for a provider instance. API keys are never stored here in
/// plaintext for persistence — [SecretRef] is a lookup key into the platform
/// secure-storage backend (macOS Keychain in production, see
/// core/security/secrets_store.dart). This object is safe to serialise to
/// disk/log because it never carries the resolved secret value.
class ProviderConfig {
  const ProviderConfig({
    required this.providerId,
    required this.baseUrl,
    this.apiKeySecretRef,
    this.defaultHeaders = const {},
    this.timeout = const Duration(seconds: 120),
  });

  final String providerId;
  final Uri baseUrl;
  final String? apiKeySecretRef;
  final Map<String, String> defaultHeaders;
  final Duration timeout;
}

/// Thrown by a provider adapter on a non-retryable failure. Retryable
/// failures (timeouts, 429s, transient 5xx) are handled internally by the
/// adapter via [ModelProvider.retryPolicy] and never surface as exceptions
/// unless retries are exhausted.
class ModelProviderException implements Exception {
  ModelProviderException(
    this.message, {
    this.statusCode,
    this.rateLimited = false,
    this.retryable = false,
  });

  final String message;
  final int? statusCode;
  final bool rateLimited;
  final bool retryable;

  @override
  String toString() => 'ModelProviderException($statusCode, $message)';
}

/// The single abstraction every model backend implements. NVIDIA NIM,
/// OpenAI, local Ollama/LM Studio endpoints, and Anthropic all conform to
/// this — nothing above this layer is allowed to special-case a provider.
abstract class ModelProvider {
  String get providerId;

  /// Discover available models and their capabilities. Providers without a
  /// discovery endpoint (e.g. a pinned local model) may return a static
  /// list built from configuration.
  Future<List<ModelDescriptor>> listModels();

  Future<ChatCompletionResult> chat(String modelName, ChatRequest request);

  Stream<ChatStreamChunk> streamChat(String modelName, ChatRequest request);

  /// Cheap reachability/auth check used by Diagnostics and the MCP-style
  /// "Test" action in provider settings.
  Future<bool> healthCheck();
}

class ModelDescriptor {
  const ModelDescriptor({
    required this.id,
    required this.capabilities,
  });

  final ModelId id;
  final ModelCapabilities capabilities;
}
