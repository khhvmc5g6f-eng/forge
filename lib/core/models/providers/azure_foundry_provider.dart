import 'dart:async';

import 'package:http/http.dart' as http;

import '../model_capabilities.dart';
import '../model_provider.dart';
import 'openai_compatible_provider.dart';

/// How requests are addressed on an Azure AI Foundry / Azure OpenAI resource.
enum AzureAddressing {
  /// `{endpoint}/openai/deployments/{deployment}/chat/completions?api-version=...`
  deployment,

  /// `{endpoint}/openai/v1/chat/completions` with the deployment name passed
  /// as the `model` field (the OpenAI-compatible surface).
  v1,
}

/// How a request authenticates against the resource.
enum AzureAuthMode {
  /// Resource key sent in the `api-key` header.
  apiKey,

  /// Microsoft Entra ID access token sent as `Authorization: Bearer <token>`.
  /// Forge does not acquire the token; supply a current one through the
  /// SecretsStore (see AZURE.md).
  bearer,
}

/// Non-secret configuration for [AzureFoundryProvider]. Nothing here is
/// hard-coded to a tenant, resource or model: every value comes from the
/// environment or settings. Secrets (key / token) are never held here, only
/// their [SecretsStore] references.
class AzureFoundrySettings {
  const AzureFoundrySettings({
    required this.endpoint,
    this.deployments = const [],
    this.apiVersion = defaultApiVersion,
    this.v1ApiVersion,
    this.addressing = AzureAddressing.deployment,
    this.authMode = AzureAuthMode.apiKey,
    this.apiKeySecretRef = defaultApiKeySecretRef,
    this.bearerTokenSecretRef = defaultBearerTokenSecretRef,
  });

  /// `api-version` used when none is configured. It is only a default;
  /// override it with FORGE_AZURE_FOUNDRY_API_VERSION to track whichever
  /// version your resource supports.
  static const String defaultApiVersion = '2024-10-21';
  static const String defaultApiKeySecretRef = 'azure_foundry_api_key';
  static const String defaultBearerTokenSecretRef = 'azure_foundry_bearer_token';

  static const String envEndpoint = 'FORGE_AZURE_FOUNDRY_ENDPOINT';
  static const String envApiKey = 'FORGE_AZURE_FOUNDRY_API_KEY';
  static const String envBearerToken = 'FORGE_AZURE_FOUNDRY_BEARER_TOKEN';
  static const String envApiVersion = 'FORGE_AZURE_FOUNDRY_API_VERSION';
  static const String envV1ApiVersion = 'FORGE_AZURE_FOUNDRY_V1_API_VERSION';
  static const String envDeployments = 'FORGE_AZURE_FOUNDRY_DEPLOYMENTS';
  static const String envAddressing = 'FORGE_AZURE_FOUNDRY_ADDRESSING';
  static const String envAuth = 'FORGE_AZURE_FOUNDRY_AUTH';

  /// Resource root, e.g. `https://<resource>.openai.azure.com/`.
  final Uri endpoint;

  /// Deployment names offered to the router. May be empty when the list is
  /// supplied entirely by an `extraModelSource`.
  final List<String> deployments;

  /// `api-version` query parameter for [AzureAddressing.deployment].
  final String apiVersion;

  /// Optional `api-version` for [AzureAddressing.v1]. Omitted when null.
  final String? v1ApiVersion;

  final AzureAddressing addressing;
  final AzureAuthMode authMode;
  final String apiKeySecretRef;
  final String bearerTokenSecretRef;

  /// Builds settings from an environment map. Returns null when the endpoint
  /// is unset or not an absolute http(s) URL, meaning "Azure not configured".
  static AzureFoundrySettings? fromEnvironment(Map<String, String> env) {
    final rawEndpoint = env[envEndpoint]?.trim() ?? '';
    if (rawEndpoint.isEmpty) return null;
    final parsed = Uri.tryParse(rawEndpoint);
    if (parsed == null ||
        !parsed.hasScheme ||
        parsed.host.isEmpty ||
        (parsed.scheme != 'https' && parsed.scheme != 'http')) {
      return null;
    }
    final endpoint = parsed.path.endsWith('/')
        ? parsed
        : parsed.replace(path: '${parsed.path}/');

    final deployments = (env[envDeployments] ?? '')
        .split(',')
        .map((d) => d.trim())
        .where((d) => d.isNotEmpty)
        .toList(growable: false);

    final apiVersion = env[envApiVersion]?.trim();
    final v1ApiVersion = env[envV1ApiVersion]?.trim();
    final addressing = (env[envAddressing] ?? '').trim().toLowerCase();
    final auth = (env[envAuth] ?? '').trim().toLowerCase();

    return AzureFoundrySettings(
      endpoint: endpoint,
      deployments: deployments,
      apiVersion: (apiVersion == null || apiVersion.isEmpty)
          ? defaultApiVersion
          : apiVersion,
      v1ApiVersion:
          (v1ApiVersion == null || v1ApiVersion.isEmpty) ? null : v1ApiVersion,
      addressing:
          addressing == 'v1' ? AzureAddressing.v1 : AzureAddressing.deployment,
      authMode: (auth == 'bearer' || auth == 'entra')
          ? AzureAuthMode.bearer
          : AzureAuthMode.apiKey,
    );
  }
}

/// Azure AI Foundry / Azure OpenAI chat provider.
///
/// Wire format, streaming and tool calling are inherited unchanged from
/// [OpenAiCompatibleProvider]; this class only changes URL construction and
/// authentication:
///
/// * deployment addressing: `openai/deployments/{deployment}/chat/completions`
///   plus `?api-version=`, or the `openai/v1/` OpenAI-compatible surface;
/// * `api-key` header, or an Entra ID bearer token.
///
/// The model list is configuration-driven ([AzureFoundrySettings.deployments])
/// and may be extended by [extraModelSource], for example the Forge Cloud
/// model catalogue. No particular model is assumed to exist.
class AzureFoundryProvider extends OpenAiCompatibleProvider {
  AzureFoundryProvider({
    required super.secretsStore,
    required this.settings,
    Map<String, String> environment = const {},
    this.extraModelSource,
    ModelCapabilities? defaultCapabilities,
    super.httpClient,
    super.maxRetries,
  })  : _environment = environment,
        _defaultCapabilities = defaultCapabilities ??
            const ModelCapabilities(supportsToolCalling: true),
        super(
          config: ProviderConfig(
            providerId: providerIdValue,
            baseUrl: settings.endpoint,
          ),
        );

  static const String providerIdValue = 'azure-foundry';

  final AzureFoundrySettings settings;

  /// Optional supplier of additional deployment names (for example from the
  /// Forge Cloud catalogue). Failures are ignored: the configured list is
  /// always returned.
  final Future<List<String>> Function()? extraModelSource;

  final Map<String, String> _environment;
  final ModelCapabilities _defaultCapabilities;

  Uri _withApiVersion(String path, String? apiVersion) {
    final uri = settings.endpoint.resolve(path);
    if (apiVersion == null || apiVersion.isEmpty) return uri;
    return uri.replace(queryParameters: {'api-version': apiVersion});
  }

  @override
  Uri chatCompletionsUri(String modelName) => chatUrl(modelName);

  @override
  Uri modelsUri() => modelsUrl();

  /// Chat-completions URL for [modelName] (the deployment name) under the
  /// configured addressing mode.
  Uri chatUrl(String modelName) {
    switch (settings.addressing) {
      case AzureAddressing.deployment:
        final deployment = Uri.encodeComponent(modelName);
        return _withApiVersion(
          'openai/deployments/$deployment/chat/completions',
          settings.apiVersion,
        );
      case AzureAddressing.v1:
        return _withApiVersion(
          'openai/v1/chat/completions',
          settings.v1ApiVersion,
        );
    }
  }

  /// Model-listing URL under the configured addressing mode.
  Uri modelsUrl() {
    switch (settings.addressing) {
      case AzureAddressing.deployment:
        return _withApiVersion('openai/models', settings.apiVersion);
      case AzureAddressing.v1:
        return _withApiVersion('openai/v1/models', settings.v1ApiVersion);
    }
  }

  Future<String?> _resolveSecret(String ref, String envName) async {
    final stored = await secrets.read(ref);
    if (stored != null && stored.isNotEmpty) return stored;
    final fromEnv = _environment[envName];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return null;
  }

  @override
  Future<Map<String, String>> requestHeaders() async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ...config.defaultHeaders,
    };
    switch (settings.authMode) {
      case AzureAuthMode.apiKey:
        final key = await _resolveSecret(
          settings.apiKeySecretRef,
          AzureFoundrySettings.envApiKey,
        );
        if (key != null) headers['api-key'] = key;
      case AzureAuthMode.bearer:
        final token = await _resolveSecret(
          settings.bearerTokenSecretRef,
          AzureFoundrySettings.envBearerToken,
        );
        if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  @override
  Future<List<ModelDescriptor>> listModels() async {
    final names = <String>[...settings.deployments];
    final source = extraModelSource;
    if (source != null) {
      try {
        for (final name in await source()) {
          if (name.isNotEmpty && !names.contains(name)) names.add(name);
        }
      } catch (_) {
        // Catalogue unavailable (offline, not signed in): configured
        // deployments still work.
      }
    }
    return names
        .map((name) => ModelDescriptor(
              id: ModelId(providerId: providerId, modelName: name),
              capabilities: capabilitiesFor(name, const {}),
            ))
        .toList(growable: false);
  }

  @override
  ModelCapabilities capabilitiesFor(String modelId, Map<String, dynamic> raw) {
    return _defaultCapabilities;
  }

  /// Unlike the base class (which lists models), this makes a real
  /// authenticated request, because the model list here is static and would
  /// always succeed.
  @override
  Future<bool> healthCheck() async {
    try {
      final headers = await requestHeaders();
      final response =
          await httpClient.get(modelsUrl(), headers: headers).timeout(config.timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
