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
class EngineCapabilities {
  const EngineCapabilities({this.version, this.actions = const {}});
  factory EngineCapabilities.fromJson(Map<String, dynamic> j) =>
      EngineCapabilities(version: jStr(j['version']), actions: jStrList(j['actions']).toSet());

  /// The engine has no action API (read-only: state + events only).
  static const none = EngineCapabilities();

  final String? version;
  final Set<String> actions;
  bool supports(String action) => actions.contains(action);
  bool get readOnly => actions.isEmpty;
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
/// `GET /forge/events` (SSE). Action API (`/forge/api/v1/*`) is *proposed* in
/// docs/ENGINE_API.md; every call degrades to [EngineErrorKind.notSupported].
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
  // Proposed routes, see docs/ENGINE_API.md. All JSON, all need the bearer token.

  static const _api = '/forge/api/v1';

  /// `GET /forge/api/v1/capabilities`. A 404 means "read-only engine".
  Future<EngineCapabilities> capabilities() async {
    try {
      final r = await _send('GET', '$_api/capabilities');
      return EngineCapabilities.fromJson(_decode(r));
    } on EngineException catch (e) {
      if (e.kind == EngineErrorKind.notSupported) return EngineCapabilities.none;
      rethrow;
    }
  }

  Future<EngineActionResult> addKey({required String providerId, required String name, required String secret, int? priority}) {
    if (!endpoint.safeForSecrets) {
      throw EngineException(
        EngineErrorKind.insecureTransport,
        'Refusing to send an API key over unencrypted HTTP to ${endpoint.host}. Use https (or a loopback tunnel).',
      );
    }
    return _action('POST', '$_api/vault/keys', {'providerId': providerId, 'name': name, 'secret': secret, 'priority': ?priority});
  }

  Future<EngineActionResult> testKey(String keyId) => _action('POST', '$_api/vault/keys/${Uri.encodeComponent(keyId)}/test', const {});
  Future<EngineActionResult> setKeyEnabled(String keyId, bool enabled) =>
      _action('PATCH', '$_api/vault/keys/${Uri.encodeComponent(keyId)}', {'enabled': enabled});
  Future<EngineActionResult> setKeyPriority(String keyId, int priority) =>
      _action('PATCH', '$_api/vault/keys/${Uri.encodeComponent(keyId)}', {'priority': priority});
  Future<EngineActionResult> removeKey(String keyId) => _action('DELETE', '$_api/vault/keys/${Uri.encodeComponent(keyId)}', null);
  Future<EngineActionResult> setProviderEnabled(String providerId, bool enabled) =>
      _action('PATCH', '$_api/vault/providers/${Uri.encodeComponent(providerId)}', {'enabled': enabled});

  /// [action]: `disable` | `enable` | `reset` | `probe`. [level]: `provider` | `key` | `model`.
  Future<EngineActionResult> circuitAction({required String level, required String id, required String action}) =>
      _action('POST', '$_api/circuits/action', {'level': level, 'id': id, 'action': action});

  Future<EngineActionResult> acknowledge({String? id, bool all = false}) =>
      _action('POST', '$_api/alerts/ack', {'id': ?id, if (all) 'all': true});

  Future<EngineActionResult> resumeGuard(String scope) => _action('POST', '$_api/guard/resume', {'scope': scope});

  // ---------------------------------------------------------- plumbing ----

  Future<EngineActionResult> _action(String method, String path, Map<String, dynamic>? body) async {
    final r = await _send(method, path, body: body);
    Map<String, dynamic> j = const {};
    try {
      j = r.body.trim().isEmpty ? const {} : jMap(jsonDecode(r.body));
    } catch (_) {}
    return EngineActionResult(ok: j['ok'] != false, message: jStr(j['message']) ?? 'Done', data: j);
  }

  Future<http.Response> _send(String method, String path, {Map<String, dynamic>? body}) async {
    final req = http.Request(method, _uri(path))..headers.addAll(_headers);
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(requestTimeout)).timeout(requestTimeout);
    } on TimeoutException {
      throw EngineException(EngineErrorKind.unreachable, 'The engine did not answer within ${requestTimeout.inSeconds}s');
    } catch (e) {
      throw EngineException(EngineErrorKind.unreachable, 'Cannot reach the engine: ${_scrub(e)}');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    throw _httpError(res.statusCode, res.body);
  }

  EngineException _httpError(int status, String body) {
    String? serverMsg;
    try {
      final j = jMap(jsonDecode(body));
      final err = j['error'];
      serverMsg = err is Map ? jStr(err['message']) : (jStr(err) ?? jStr(j['message']));
    } catch (_) {}
    if (status == 401 || status == 403) {
      return EngineException(EngineErrorKind.unauthorized,
          status == 401 ? 'The engine rejected the token (HTTP 401). Re-pair with a valid token.' : 'The engine denied access (HTTP 403).',
          statusCode: status);
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

  /// Never let the bearer token appear in an error string.
  String _scrub(Object e) {
    var s = '$e';
    final t = token;
    if (t != null && t.isNotEmpty) s = s.replaceAll(t, '***');
    return s;
  }
}
