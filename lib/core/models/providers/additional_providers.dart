
import '../model_capabilities.dart';
import '../model_provider.dart';
import 'openai_compatible_provider.dart';

/// Groq — OpenAI-compatible, exceptionally low-latency inference. Per the
/// Control Plane spec: "particularly useful for extremely fast inference;
/// worker tasks; classification; tool orchestration; fast code analysis;
/// parallel subagents." Base URL confirmed current as of this writing via
/// Groq's own docs (`https://api.groq.com/openai/v1`).
class GroqProvider extends OpenAiCompatibleProvider {
  GroqProvider({
    required super.secretsStore,
    String apiKeySecretRef = 'groq_api_key',
    Uri? baseUrl,
    super.httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'groq',
            baseUrl: baseUrl ?? Uri.parse('https://api.groq.com/openai/v1/'),
            apiKeySecretRef: apiKeySecretRef,
          ),
        );

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    // Groq's free tier is generous but rate-limited rather than unlimited;
    // treated as free here for routing purposes per the spec's FREE WITH
    // LIMITS category — the Model Arena/registry refines this empirically.
    return const ModelCapabilities(supportsToolCalling: true, isFree: true);
  }
}

/// Cerebras — another independent high-speed provider, per the spec: "an
/// important additional failure domain." Base URL confirmed current via
/// Cerebras's own OpenAI-compatibility docs.
class CerebrasProvider extends OpenAiCompatibleProvider {
  CerebrasProvider({
    required super.secretsStore,
    String apiKeySecretRef = 'cerebras_api_key',
    Uri? baseUrl,
    super.httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'cerebras',
            baseUrl: baseUrl ?? Uri.parse('https://api.cerebras.ai/v1/'),
            apiKeySecretRef: apiKeySecretRef,
          ),
        );

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return const ModelCapabilities(supportsToolCalling: true, isFree: true);
  }
}

/// OpenRouter — a meta-provider fronting many upstream models behind one
/// OpenAI-compatible API and key; useful as a further independent failure
/// domain per the spec's "OpenRouter" fallback tier.
class OpenRouterProvider extends OpenAiCompatibleProvider {
  OpenRouterProvider({
    required super.secretsStore,
    String apiKeySecretRef = 'openrouter_api_key',
    Uri? baseUrl,
    super.httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'openrouter',
            baseUrl: baseUrl ?? Uri.parse('https://openrouter.ai/api/v1/'),
            apiKeySecretRef: apiKeySecretRef,
            // OpenRouter requires/recommends these for attribution; harmless
            // to send and improves routing/analytics on their side.
            defaultHeaders: const {
              'HTTP-Referer': 'https://forge.local',
              'X-Title': 'Forge',
            },
          ),
        );

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    // OpenRouter's /v1/models response includes real pricing; a per-model
    // free/paid distinction from `raw['pricing']` is a refinement left to
    // the Model Registry rather than guessed here.
    final pricing = raw['pricing'] as Map<String, dynamic>?;
    final isFree = pricing == null || (pricing['prompt'] == '0' && pricing['completion'] == '0');
    return ModelCapabilities(supportsToolCalling: true, isFree: isFree);
  }
}

/// Z.AI (GLM family) — OpenAI-compatible. Base URL confirmed current via
/// Z.AI's own developer docs (`https://api.z.ai/api/paas/v4`); Z.AI also
/// exposes a GLM-Coding-Plan-specific base URL
/// (`https://api.z.ai/api/coding/paas/v4`) for accounts on that plan, passed
/// via the `baseUrl` constructor parameter when applicable.
class ZaiProvider extends OpenAiCompatibleProvider {
  ZaiProvider({
    required super.secretsStore,
    String apiKeySecretRef = 'zai_api_key',
    Uri? baseUrl,
    super.httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'zai',
            baseUrl: baseUrl ?? Uri.parse('https://api.z.ai/api/paas/v4/'),
            apiKeySecretRef: apiKeySecretRef,
          ),
        );

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return const ModelCapabilities(supportsToolCalling: true, isFree: false);
  }
}

/// Google Gemini via its official OpenAI-compatibility endpoint
/// (`https://generativelanguage.googleapis.com/v1beta/openai/`) rather than
/// a bespoke `generateContent` REST client — Google documents this as a
/// first-class, request-shape-compatible surface (`/chat/completions`,
/// `/embeddings`), so it fits the same `OpenAiCompatibleProvider` base every
/// other provider in this file uses, with no loss of capability for Forge's
/// purposes (tool calling, streaming). Feature parity is not guaranteed to
/// be perfect for every parameter (per Google's own compatibility notes),
/// which the Model Registry's empirical scoring will surface if it matters.
class GoogleProvider extends OpenAiCompatibleProvider {
  GoogleProvider({
    required super.secretsStore,
    String apiKeySecretRef = 'google_api_key',
    Uri? baseUrl,
    super.httpClient,
  }) : super(
          config: ProviderConfig(
            providerId: 'google',
            baseUrl: baseUrl ?? Uri.parse('https://generativelanguage.googleapis.com/v1beta/openai/'),
            apiKeySecretRef: apiKeySecretRef,
          ),
        );

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return const ModelCapabilities(supportsToolCalling: true, supportsVision: true, isFree: false);
  }
}
