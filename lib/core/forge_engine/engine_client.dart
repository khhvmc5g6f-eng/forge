import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'engine_endpoint.dart';
import 'engine_models.dart';
import 'json_util.dart';

enum EngineErrorKind {
  /// Network failure, timeout, TLS failure: the engine could not be reached.
  unreachable,

  /// HTTP 401/403: missing, wrong or expired bearer token.
  unauthorized,

  /// HTTP 404/405/501 on an action route: this engine build does not expose it
  /// (see docs/ENGINE_API.md).
  notSupported,

  /// The engine understood and refused (HTTP 4xx with a message).
  rejected,

  /// HTTP 5xx.
  server,

  /// A 200 whose body is not the expected JSON.
  malformed,

  /// The client refused to send a secret over an unencrypted off-device link.
  insecureTransport,
}

class EngineException implements Exception {
  EngineException(this.kind, this.message, {this.statusCode});
  final EngineErrorKind kind;
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// What this engine build lets a client change. Discovered, never assumed.
///
/// The real engine has no capabilities endpoint: the management API
/// (`/forge/api/*`) is either mounted (it answers `GET /forge/api/budget` with
/// the bearer token) or not (404). [EngineClient.capabilities] probes that and
/// fills [actions] with the operations the real API implements.
class EngineCapabilities {
  const EngineCapabilities({this.version, this.actions = const {}, this.authRejected = false});
  factory EngineCapabilities.fromJson(Map<String, dynamic> j) =>
      EngineCapabilities(version: jStr(j['version']), actions: jStrList(j['actions']).toSet());

  /// The engine has no action API (read-only: state + events only).
  static const none = EngineCapabilities();

  /// The management API answered 401/403: it exists but needs a (valid) bearer token.
  static const authRequired = EngineCapabilities(authRejected: true);

  /// Everything the engine's management API (`control-api.ts`) can do today.
  static const managementApi = EngineCapabilities(version: 'forge-api', actions: managementActions);

  /// Action ids the real `/forge/api/*` implements.
  static const managementActions = {'key.add', 'key.test', 'key.update', 'key.remove', 'circuit.action'};

  /// Why an action the UI knows about is still unavailable even on an engine that has the management API.
  static const unsupportedReasons = {
    'key.priority': 'The engine API cannot change a key\'s priority yet; do it in the Forge desktop app or forge.yaml',
    'provider.update': 'The engine API cannot enable or disable a provider yet (it needs the full provider definition); do it in the Forge desktop app',
    'alert.ack': 'The engine API has no alert acknowledgement endpoint yet; acknowledge alerts in the Forge desktop app',
    'guard.resume': 'The engine API has no runaway-guard resume endpoint yet; resume in the Forge desktop app',
  };

  final String? version;
  final Set<String> actions;
  final bool authRejected;
  bool supports(String action) => actions.contains(action);
  bool get readOnly => actions.isEmpty && !authRejected;
}

class EngineActionResult {
  const EngineActionResult({required this.ok, required this.message, this.data = const {}});
  final bool ok;
  final String message;
  final Map<String, dynamic> data;
}

/// One parsed SSE frame.
class SseFrame {
  const SseFrame({this.id, this.event, required this.data});
  final String? id, event;
  final String data;
}

/// Incremental SSE parser (WHATWG rules we need: `data:` lines joined with
/// `\n`, `id:`, `event:`, `:` comments, blank line dispatches a frame, CRLF ok).
Stream<SseFrame> parseSse(Stream<List<int>> bytes) async* {
  String? id, event;
  final data = <String>[];
  await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield SseFrame(id: id, event: event, data: data.join('\n'));
      id = null;
      event = null;
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue;
    final i = line.indexOf(':');
    final field = i < 0 ? line : line.substring(0, i);
    var value = i < 0 ? '' : line.substring(i + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        data.add(value);
      case 'id':
        id = value;
      case 'event':
        event = value;
    }
  }
  // The engine frames each event with a trailing blank line; a half frame at
  // end-of-stream is dropped rather than guessed at.
}

/// HTTP client for the Forge engine's control-plane surface. Stateless apart
/// from the injected [http.Client]; the connection manager owns lifecycle.
///
/// Read API (exists today): `GET /forge/state`, `GET /forge/health`,
/// `GET /forge/events` (SSE). Actions use the engine's token-gated management
/// API (`/forge/api/*`, `control-api.ts`); an engine that does not mount it
/// answers 404 and every call degrades to [EngineErrorKind.notSupported].
class EngineClient {
  EngineClient({
    required this.endpoint,
    this.token,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _http = httpClient ?? http.Client();

  final EngineEndpoint endpoint;
  final String? token;
  final Duration requestTimeout;
  final http.Client _http;

  Map<String, String> get _headers => {
        'accept': 'application/json',
        if (token != null && token!.isNotEmpty) 'authorization': 'Bearer $token',
      };

  Uri _uri(String path) => endpoint.baseUri.resolve(path);

  void close() => _http.close();

  // ------------------------------------------------------------ reads ----

  Future<EngineState> fetchState() async {
    final r = await _send('GET', '/forge/state');
    final j = _decode(r);
    return EngineState.fromJson(j);
  }

  /// `GET /forge/health` -> `{ ok, keys }`.
  Future<bool> health() async {
    final r = await _send('GET', '/forge/health');
    return _decode(r)['ok'] == true;
  }

  /// Opens the SSE feed, asking the engine to replay events after [afterSeq].
  /// [onOpen] fires once the engine has accepted the stream (HTTP 200); the
  /// engine sends nothing until something happens, so this is the only
  /// "connected" signal. The stream ends when the connection drops; errors are
  /// surfaced as [EngineException]. Malformed frames are skipped.
  Stream<EngineEvent> events({int afterSeq = 0, void Function()? onOpen}) async* {
    final req = http.Request('GET', _uri('/forge/events'))
      ..headers.addAll({..._headers, 'accept': 'text/event-stream', 'cache-control': 'no-cache', 'last-event-id': '$afterSeq'});
    http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(requestTimeout);
    } on TimeoutException {
      throw EngineException(EngineErrorKind.unreachable, 'Timed out opening the event stream');
    } catch (e) {
      throw EngineException(EngineErrorKind.unreachable, 'Event stream failed: ${_scrub(e)}');
    }
    if (res.statusCode != 200) {
      await res.stream.drain<void>().catchError((_) {});
      throw _httpError(res.statusCode, '');
    }
    onOpen?.call();
    try {
      await for (final f in parseSse(res.stream)) {
        try {
          final e = EngineEvent.tryParse(jsonDecode(f.data));
          if (e != null) yield e;
        } catch (_) {
          // Skip malformed frames; never invent an event.
        }
      }
    } catch (e) {
      throw EngineException(EngineErrorKind.unreachable, 'Event stream interrupted: ${_scrub(e)}');
    }
  }

  // ---------------------------------------------------------- actions ----
  // The engine's management API (`sdk/packages/forge/src/control-api.ts`).
  // Every route needs `Authorization: Bearer <gateway token>` (no loopback
  // exemption) and is loopback-only on the engine side. Secrets only go in;
  // no response carries one.

  static const _api = '/forge/api';

  /// Probes whether the engine mounts the management API. The real engine has
  /// no capabilities route, so this asks for the (read-only) budget report:
  /// 200 = mounted and the token works, 404 = read-only engine, 401/403 =
  /// mounted but the token is missing or wrong.
  Future<EngineCapabilities> capabilities() async {
    try {
      await _send('GET', '$_api/budget');
      return EngineCapabilities.managementApi;
    } on EngineException catch (e) {
      if (e.kind == EngineErrorKind.notSupported) return EngineCapabilities.none;
      if (e.kind == EngineErrorKind.unauthorized) return EngineCapabilities.authRequired;
      rethrow;
    }
  }

  /// `POST /forge/api/keys`. The engine stores the secret in the OS credential
  /// store and answers with the masked key (`data['id']` is the new key id).
  Future<EngineActionResult> addKey({required String providerId, required String name, required String secret, int? priority}) {
    if (!endpoint.safeForSecrets) {
      throw EngineException(
        EngineErrorKind.insecureTransport,
        'Refusing to send an API key over unencrypted HTTP to ${endpoint.host}. Use https (or a loopback tunnel).',
      );
    }
    return _action('POST', '$_api/keys', {'providerId': providerId, 'name': name, 'secret': secret, 'priority': ?priority},
        timeout: const Duration(seconds: 30), done: 'Key "$name" stored in the engine vault');
  }

  /// `POST /forge/api/keys/{id}/test`: discovery plus a real provider call (flagged as a test by the engine).
  Future<EngineActionResult> testKey(String keyId, {String? modelId}) =>
      _action('POST', '$_api/keys/${Uri.encodeComponent(keyId)}/test', {'modelId': ?modelId}, timeout: const Duration(seconds: 60), testResult: true);

  /// `POST /forge/api/keys/{id}/enabled`.
  Future<EngineActionResult> setKeyEnabled(String keyId, bool enabled) =>
      _action('POST', '$_api/keys/${Uri.encodeComponent(keyId)}/enabled', {'enabled': enabled}, done: enabled ? 'Key enabled' : 'Key disabled');

  /// `DELETE /forge/api/keys/{id}`.
  Future<EngineActionResult> removeKey(String keyId) =>
      _action('DELETE', '$_api/keys/${Uri.encodeComponent(keyId)}', null, done: 'Key removed from the engine vault');

  /// `POST /forge/api/circuits`. [action]: `disable` | `enable` | `reset` | `probe`.
  /// [level]: `provider` | `key` | `model`; [keyId] is required for key and
  /// model circuits and [modelId] for model circuits (the engine says so otherwise).
  Future<EngineActionResult> circuitAction({required String level, required String providerId, String? keyId, String? modelId, required String action}) =>
      _action('POST', '$_api/circuits', {'level': level, 'providerId': providerId, 'keyId': ?keyId, 'modelId': ?modelId, 'action': action},
          done: 'Circuit $action done');

  // ---------------------------------------------------------- plumbing ----

  Future<EngineActionResult> _action(String method, String path, Map<String, dynamic>? body,
      {Duration? timeout, String done = 'Done', bool testResult = false}) async {
    final r = await _send(method, path, body: body, timeout: timeout);
    Map<String, dynamic> j = const {};
    try {
      j = r.body.trim().isEmpty ? const {} : jMap(jsonDecode(r.body));
    } catch (_) {}
    if (testResult) {
      // ApiTestResult: { name, status: pass|fail|skipped|unsupported|rate_limited, detail?, durationMs, test: true }
      final status = jStr(j['status']) ?? 'unknown';
      final detail = jStr(j['detail']);
      return EngineActionResult(ok: status == 'pass', message: 'Key test: $status${detail == null ? '' : ' ($detail)'}', data: j);
    }
    // circuits: { ok, detail? }; keys: KeyDisplay (no `ok`); delete/enabled: { ok: true }
    return EngineActionResult(ok: j['ok'] != false, message: jStr(j['message']) ?? jStr(j['detail']) ?? done, data: j);
  }

  Future<http.Response> _send(String method, String path, {Map<String, dynamic>? body, Duration? timeout}) async {
    final limit = timeout ?? requestTimeout;
    final req = http.Request(method, _uri(path))..headers.addAll(_headers);
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(limit)).timeout(limit);
    } on TimeoutException {
      throw EngineException(EngineErrorKind.unreachable, 'The engine did not answer within ${limit.inSeconds}s');
    } catch (e) {
      throw EngineException(EngineErrorKind.unreachable, 'Cannot reach the engine: ${_scrub(e)}');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    throw _httpError(res.statusCode, res.body);
  }

  EngineException _httpError(int status, String body) {
    String? serverMsg, errType;
    try {
      final j = jMap(jsonDecode(body));
      final err = j['error'];
      serverMsg = err is Map ? jStr(err['message']) : (jStr(err) ?? jStr(j['message']));
      errType = err is Map ? jStr(err['type']) : null;
    } catch (_) {}
    if (status == 401 || status == 403) {
      return EngineException(EngineErrorKind.unauthorized,
          status == 401 ? 'The engine rejected the token (HTTP 401). Re-pair with a valid token.' : 'The engine denied access (HTTP 403).',
          statusCode: status);
    }
    // The management API answers 404 for "that key/provider does not exist": a refusal, not a missing API.
    if (status == 404 && errType != null && errType != 'forge_not_found') {
      return EngineException(EngineErrorKind.rejected, serverMsg ?? 'Engine refused the request (HTTP 404)', statusCode: status);
    }
    if (status == 404 || status == 405 || status == 501) {
      return EngineException(EngineErrorKind.notSupported, 'This engine does not expose that endpoint (HTTP $status).', statusCode: status);
    }
    if (status >= 500) {
      return EngineException(EngineErrorKind.server, 'Engine error (HTTP $status)${serverMsg == null ? '' : ': $serverMsg'}', statusCode: status);
    }
    return EngineException(EngineErrorKind.rejected, serverMsg ?? 'Engine refused the request (HTTP $status)', statusCode: status);
  }

  Map<String, dynamic> _decode(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map) return j.cast<String, dynamic>();
    } catch (_) {}
    throw EngineException(EngineErrorKind.malformed, 'The engine answered with something that is not Forge state JSON.');
  }

  /// Short, readable network error with the token removed. `SocketException`
  /// detail is reduced to the OS message (e.g. "Connection refused").
  String _scrub(Object e) {
    var s = '$e';
    final os = RegExp(r'OS Error: ([^,)]+)').firstMatch(s);
    if (os != null) {
      s = os.group(1)!.trim();
    } else if (s.length > 140) {
      s = '${s.substring(0, 140)}…';
    }
    final t = token;
    if (t != null && t.isNotEmpty) s = s.replaceAll(t, '***');
    return s;
  }
}
