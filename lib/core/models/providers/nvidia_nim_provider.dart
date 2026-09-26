
import '../model_capabilities.dart';
import '../model_provider.dart';
import 'openai_compatible_provider.dart';

/// NVIDIA NIM is a first-class provider: an OpenAI-compatible
/// `/v1/chat/completions` + `/v1/models` surface hosted at
/// `https://integrate.api.nvidia.com/v1` (or a self-hosted NIM microservice
/// base URL for on-prem/local deployment). It differs from generic
/// OpenAI-compatible endpoints only in auth and in the extra metadata NVIDIA
/// includes on some model listings.
class NvidiaNimProvider extends OpenAiCompatibleProvider {
  NvidiaNimProvider({
    required super.secretsStore,
    Uri? baseUrl,
    String apiKeySecretRef = 'nvidia_nim_api_key',
    super.httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'nvidia-nim',
            baseUrl: baseUrl ?? Uri.parse('https://integrate.api.nvidia.com/v1/'),
            apiKeySecretRef: apiKeySecretRef,
          ),
        );

  /// Curated capability overrides for the NVIDIA-hosted models Forge treats
  /// as agentic-coding-capable by default. This is a starting point, not a
  /// source of truth — the Model Arena (core/models/model_registry.dart)
  /// overwrites these with empirically observed reliability scores, and any
  /// model absent from this map still gets a conservative default rather
  /// than being excluded.
  static final Map<String, ModelCapabilities> _knownModels = {
    'meta/llama-3.3-70b-instruct': const ModelCapabilities(
      supportsToolCalling: true,
      contextWindowTokens: 128000,
      maxOutputTokens: 4096,
      isFree: true,
    ),
    'qwen/qwen2.5-coder-32b-instruct': const ModelCapabilities(
      supportsToolCalling: true,
      contextWindowTokens: 32768,
      maxOutputTokens: 8192,
      isFree: true,
    ),
    'deepseek-ai/deepseek-r1': const ModelCapabilities(
      supportsToolCalling: true,
      supportsReasoningEffort: true,
      contextWindowTokens: 128000,
      maxOutputTokens: 8192,
      isFree: true,
    ),
    'nvidia/llama-3.1-nemotron-70b-instruct': const ModelCapabilities(
      supportsToolCalling: true,
      contextWindowTokens: 128000,
      maxOutputTokens: 4096,
      isFree: true,
    ),
  };

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return _knownModels[modelId] ?? const ModelCapabilities(isFree: false);
  }
}
