import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';

import 'engine_client_test.dart' show until;

/// Opt-in: runs the client against a REAL Forge engine (the TypeScript control plane).
///
///   cd /Volumes/Mac\ Laptop/Forge/sdk/packages/forge
///   bun scripts/forge-gateway.ts --port 8791 --home /tmp/forge-home --memory-secrets --ollama
///   FORGE_LIVE_ENGINE=http://127.0.0.1:8791 flutter test test/forge_engine/live_engine_test.dart
///
/// Add FORGE_LIVE_TOKEN=... once the gateway enforces bearer auth.
void main() {
  final url = Platform.environment['FORGE_LIVE_ENGINE'];
  final token = Platform.environment['FORGE_LIVE_TOKEN'];
  final skip = url == null ? 'set FORGE_LIVE_ENGINE=http://127.0.0.1:8791 to run against a real engine' : null;

  test('real engine: state parses, event stream opens, real traffic shows up as typed events', () async {
    final p = parsePairing(url!)!;
    final conn = EngineConnection(pollInterval: const Duration(milliseconds: 500));
    addTearDown(conn.dispose);
    final seen = <EngineEvent>[];
    final flow = LiveFlowModel();
    conn.eventStream.listen((e) {
      seen.add(e);
      flow.ingest(e, now: DateTime.now());
    });
    await conn.configure(p.endpoint, token: token ?? p.token, persist: false);
    await until(() => conn.isConnected && conn.eventsLive, timeout: const Duration(seconds: 10));

    final s = conn.state!;
    expect(s.providers, isNotEmpty);
    expect(s.keys, isNotEmpty);
    expect(s.keys.first.masked, isNotNull);
    expect(s.keys.first.masked, isNot(contains('local-no-auth')), reason: 'the engine masks secrets');
    expect(s.keys.first.health!.score, isNull, reason: 'no traffic yet means no score, not 100');
    await until(() => conn.capabilitiesKnown);
    // Today's engine has no action API.
    expect(conn.capabilities.readOnly, isTrue);

    // Real traffic: a chat completion through the gateway. The upstream (Ollama) may be absent, which is fine: the
    // gateway still emits its real MODEL_REQUEST_STARTED / KEY_SELECTED / FAILED / FAILOVER events.
    final http = HttpClient();
    final req = await http.postUrl(p.endpoint.baseUri.resolve('/v1/chat/completions'));
    req.headers.contentType = ContentType.json;
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    req.headers.set('x-forge-agent', 'flutter-live-test');
    req.write(jsonEncode({
      'model': 'does-not-matter',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ]
    }));
    final res = await req.close();
    await res.drain<void>();
    http.close();

    await until(() => seen.any((e) => e.type == 'MODEL_REQUEST_STARTED'), timeout: const Duration(seconds: 10));
    await until(() => flow.recent.isNotEmpty, timeout: const Duration(seconds: 15));
    final started = seen.firstWhere((e) => e.type == 'MODEL_REQUEST_STARTED');
    expect(started.agentId, 'flutter-live-test');
    expect(started.requestId, isNotNull);
    final r = flow.recent.first;
    expect(r.agentId, 'flutter-live-test');
    expect(r.inFlight, isFalse);
    // State refreshes after the events: the request is now counted.
    await until(() => (conn.state?.totals.calls ?? 0) + (conn.state?.routing.decisions ?? 0) > 0, timeout: const Duration(seconds: 10));

    final g = EngineGraph()..applyState(conn.state!);
    for (final e in seen) {
      g.applyEvent(e);
    }
    expect(g.nodes.keys, contains('agent:flutter-live-test'));
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
