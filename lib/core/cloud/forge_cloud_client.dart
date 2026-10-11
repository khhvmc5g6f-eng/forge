import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../security/secrets_store.dart';
import 'cloud_models.dart';
import 'cloud_routes.dart';

/// Environment variable naming the Forge Cloud base URL. Unset means cloud
/// features are disabled and every surface says "Forge Cloud not configured".
const String forgeCloudUrlEnvVar = 'FORGE_CLOUD_URL';

/// SecretsStore reference under which the Forge Cloud access token is kept.
const String forgeCloudTokenSecretRef = 'forge_cloud_token';

/// Text shown by the UI and CLI when no Forge Cloud URL is configured.
const String forgeCloudNotConfiguredMessage = 'Forge Cloud not configured';

/// Parses a Forge Cloud base URL from a raw string (environment or
/// settings). Returns null when empty or not an absolute http(s) URL.
Uri? parseForgeCloudUrl(String? raw) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  return uri;
}

class ForgeCloudException implements Exception {
  ForgeCloudException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthenticated => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'ForgeCloudException($statusCode, $message)';
}

/// Thrown when a cloud operation is requested but no base URL is set.
class ForgeCloudNotConfiguredException implements Exception {
  const ForgeCloudNotConfiguredException();

  @override
  String toString() => forgeCloudNotConfiguredMessage;
}

/// Typed client for the Forge Azure backend. Paths come from
/// [ForgeCloudRoutes]. The access token is read from the [SecretsStore] on
/// each call and is never logged or included in exception messages. The
/// [http.Client] is injected so tests use a fake transport.
class ForgeCloudClient {
  ForgeCloudClient({
    required this.baseUrl,
    required SecretsStore secretsStore,
    http.Client? httpClient,
    this.tokenSecretRef = forgeCloudTokenSecretRef,
    this.timeout = const Duration(seconds: 30),
  })  : _secrets = secretsStore,
        _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final String tokenSecretRef;
  final Duration timeout;
  final SecretsStore _secrets;
  final http.Client _http;

  Uri _uri(String path) {
    final basePath = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(path: '$basePath$path');
  }

  Future<bool> hasToken() async {
    final token = await _secrets.read(tokenSecretRef);
    return token != null && token.isNotEmpty;
  }

  Future<void> signOut() => _secrets.delete(tokenSecretRef);

  Future<Map<String, String>> _headers({required bool authenticated}) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (authenticated) {
      final token = await _secrets.read(tokenSecretRef);
      if (token == null || token.isEmpty) {
        throw ForgeCloudException('Not signed in to Forge Cloud.',
            statusCode: 401);
      }
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  Future<Object?> _decode(http.Response response) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ForgeCloudException(
        'Forge Cloud returned HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw ForgeCloudException('Forge Cloud returned invalid JSON.',
          statusCode: response.statusCode);
    }
  }

  Future<Object?> _get(String path) async {
    final headers = await _headers(authenticated: true);
    try {
      final response =
          await _http.get(_uri(path), headers: headers).timeout(timeout);
      return await _decode(response);
    } on TimeoutException {
      throw ForgeCloudException('Forge Cloud request timed out.');
    } on http.ClientException catch (e) {
      throw ForgeCloudException('Forge Cloud unreachable: ${e.message}');
    }
  }

  Future<Object?> _post(
    String path,
    Map<String, dynamic> body, {
    required bool authenticated,
  }) async {
    final headers = await _headers(authenticated: authenticated);
    try {
      final response = await _http
          .post(_uri(path), headers: headers, body: jsonEncode(body))
          .timeout(timeout);
      return await _decode(response);
    } on TimeoutException {
      throw ForgeCloudException('Forge Cloud request timed out.');
    } on http.ClientException catch (e) {
      throw ForgeCloudException('Forge Cloud unreachable: ${e.message}');
    }
  }

  // ── Device-code sign-in ────────────────────────────────────────────────

  Future<DeviceCodeIssue> issueDeviceCode() async {
    final json = await _post(ForgeCloudRoutes.deviceCodeIssue, const {},
        authenticated: false);
    return DeviceCodeIssue.fromJson(json);
  }

  Future<DeviceCodeRedeemResult> redeemDeviceCode(String deviceCode) async {
    final json = await _post(
      ForgeCloudRoutes.deviceCodeRedeem,
      {'deviceCode': deviceCode},
      authenticated: false,
    );
    return DeviceCodeRedeemResult.fromJson(json);
  }

  /// Polls [redeemDeviceCode] every `issue.intervalSeconds` until the code is
  /// approved, denied or expired, or `issue.expiresInSeconds` elapses. On
  /// approval the access token is written to the SecretsStore and only the
  /// terminal status is returned (the token is not exposed). [delay] is
  /// injectable so tests do not wait in real time.
  Future<DeviceCodeStatus> pollDeviceCode(
    DeviceCodeIssue issue, {
    Future<void> Function(Duration)? delay,
  }) async {
    final wait = delay ?? (Duration d) => Future<void>.delayed(d);
    final interval =
        Duration(seconds: issue.intervalSeconds < 1 ? 1 : issue.intervalSeconds);
    var elapsed = Duration.zero;
    final limit = Duration(seconds: issue.expiresInSeconds);
    while (elapsed <= limit) {
      final result = await redeemDeviceCode(issue.deviceCode);
      switch (result.status) {
        case DeviceCodeStatus.approved:
          await _secrets.write(tokenSecretRef, result.accessToken!);
          return DeviceCodeStatus.approved;
        case DeviceCodeStatus.denied:
          return DeviceCodeStatus.denied;
        case DeviceCodeStatus.expired:
          return DeviceCodeStatus.expired;
        case DeviceCodeStatus.pending:
          break;
      }
      await wait(interval);
      elapsed += interval;
    }
    return DeviceCodeStatus.expired;
  }

  // ── Authenticated reads ────────────────────────────────────────────────

  Future<WalletBalance> getWalletBalance() async =>
      WalletBalance.fromJson(await _get(ForgeCloudRoutes.walletBalance));

  Future<UsageSummary> getUsageSummary() async =>
      UsageSummary.fromJson(await _get(ForgeCloudRoutes.usageSummary));

  Future<ModelCatalogue> getModelCatalogue() async =>
      ModelCatalogue.fromJson(await _get(ForgeCloudRoutes.models));

  Future<CostEstimate> estimateCost(CostEstimateRequest request) async {
    final json = await _post(ForgeCloudRoutes.estimate, request.toJson(),
        authenticated: true);
    return CostEstimate.fromJson(json);
  }

  void close() => _http.close();
}
