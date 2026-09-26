import 'package:http/http.dart' as http;

import '../../security/secrets_store.dart';
import '../model_capabilities.dart';
import '../model_provider.dart';
import 'openai_compatible_provider.dart';

/// Local Ollama server (default `http://localhost:11434/v1/`). No API key
/// required; treated as free and local for routing purposes.
class OllamaProvider extends OpenAiCompatibleProvider {
  OllamaProvider({
    required SecretsStore secretsStore,
    Uri? baseUrl,
    http.Client? httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'ollama',
            baseUrl: baseUrl ?? Uri.parse('http://localhost:11434/v1/'),
          ),
          secretsStore: secretsStore,
          httpClient: httpClient,
        );

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return const ModelCapabilities(isFree: true, isLocal: true);
  }
}

/// Local LM Studio server (default `http://localhost:1234/v1/`).
class LmStudioProvider extends OpenAiCompatibleProvider {
  LmStudioProvider({
    required SecretsStore secretsStore,
    Uri? baseUrl,
    http.Client? httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'lm-studio',
            baseUrl: baseUrl ?? Uri.parse('http://localhost:1234/v1/'),
          ),
          secretsStore: secretsStore,
          httpClient: httpClient,
        );

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return const ModelCapabilities(isFree: true, isLocal: true);
  }
}

/// Any other user-supplied OpenAI-compatible endpoint (self-hosted vLLM,
/// text-generation-webui, a future provider not yet given a dedicated
/// adapter). Configured entirely from [ProviderConfig] with no built-in
/// capability table — the user or the Model Arena establishes capabilities
/// empirically.
class GenericOpenAiCompatibleProvider extends OpenAiCompatibleProvider {
  GenericOpenAiCompatibleProvider({
    required super.config,
    required super.secretsStore,
    super.httpClient,
  });
}

/// Official OpenAI API.
class OpenAiProvider extends OpenAiCompatibleProvider {
  OpenAiProvider({
    required SecretsStore secretsStore,
    String apiKeySecretRef = 'openai_api_key',
    Uri? baseUrl,
    http.Client? httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'openai',
            baseUrl: baseUrl ?? Uri.parse('https://api.openai.com/v1/'),
            apiKeySecretRef: apiKeySecretRef,
          ),
          secretsStore: secretsStore,
          httpClient: httpClient,
        );
}
