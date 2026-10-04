import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';
import 'package:forge/core/security/secrets_store.dart';

import 'engine_client_test.dart' show until;

/// Opt-in: runs the client against a REAL Forge engine (the TypeScript control plane).
///
///   cd /Volumes/Mac\ Laptop/Forge/sdk/packages/forge
///   bun scripts/forge-gateway.ts --port 8791 --home /tmp/forge-home --memory-secrets --ollama
///   FORGE_LIVE_ENGINE=http://127.0.0.1:8791 flutter test test/forge_engine/live_engine_test.dart
///
/// Management API (key add/test/enable/remove, circuit actions) needs an engine created with
/// `createControlPlane({ management: { token } })`; pass that token as FORGE_LIVE_TOKEN and set
/// FORGE_LIVE_MANAGEMENT=1 to also run the action tests below. The engine must have a provider
/// with id `openai` and an `ollama` provider (see the scratch script used for the verification
/// in docs/ENGINE_API.md section 7).
void main() {
  final url = Platform.environment['FORGE_LIVE_ENGINE'];
  final token = Platform.environment['FORGE_LIVE_TOKEN'];
  final management = Platform.environment['FORGE_LIVE_MANAGEMENT'] == '1';
  final skip = url == null ? 'set FORGE_LIVE_ENGINE=http://127.0.0.1:8791 to run against a real engine' : null;
  final skipMgmt = url == null || !management ? 'set FORGE_LIVE_ENGINE, FORGE_LIVE_TOKEN and FORGE_LIVE_MANAGEMENT=1 (engine with the management API enabled)' : null;

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
    // Real traffic first: an idle engine sends no SSE response headers until its first event (no `: open` comment),
    // so the stream only opens once something happens. A chat completion through the gateway. The upstream (Ollama) may be absent, which is fine: the
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

    // (not awaited before: the stream open resolves once the engine emits its first event)
    await until(() => conn.isConnected && conn.eventsLive, timeout: const Duration(seconds: 10));

    final s = conn.state!;
    expect(s.providers, isNotEmpty);
    expect(s.keys, isNotEmpty);
    expect(s.keys.first.masked, isNotNull);
    expect(s.keys.first.masked, isNot(contains('local-no-auth')), reason: 'the engine masks secrets');
    expect(s.keys.first.health, isNotNull);
    await until(() => conn.capabilitiesKnown);
    if (management) {
      expect(conn.capabilities.supports('key.add'), isTrue);
      expect(conn.capabilities.supports('circuit.action'), isTrue);
    } else {
      // An engine started without `management` does not mount /forge/api/*.
      expect(conn.capabilities.readOnly, isTrue);
    }

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

  test('real management API: bearer gate, key add/test/enable/remove, circuit actions, legacy-key migration', () async {
    final p = parsePairing(url!)!;
    EngineClient client(String? t) => EngineClient(endpoint: p.endpoint, token: t, requestTimeout: const Duration(seconds: 20));

    // 1. No token / wrong token: the management API exists but refuses.
    for (final bad in [null, 'wrong-token']) {
      final c = client(bad);
      expect((await c.capabilities()).authRejected, isTrue);
      await expectLater(c.removeKey('anything'), throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.unauthorized)));
      c.close();
    }

    final conn = EngineConnection(pollInterval: const Duration(milliseconds: 300));
    addTearDown(conn.dispose);
    await conn.configure(p.endpoint, token: token, persist: false);
    await until(() => conn.isConnected && conn.capabilitiesKnown);
    expect(conn.capabilities.supports('key.add'), isTrue);

    // 2. add: the engine answers with the masked key, never the secret.
    const secret = 'sk-live-test-secret-DO-NOT-LEAK-1234';
    final added = await conn.run((c) => c.addKey(providerId: 'openai', name: 'flutter-live', secret: secret, priority: 5));
    expect(added.ok, isTrue);
    final id = added.data['id'] as String;
    expect(added.data.toString(), isNot(contains(secret)));
    final listed = conn.state!.keys.firstWhere((k) => k.id == id);
    expect(listed.name, 'flutter-live');
    expect(listed.masked, isNot(contains(secret)));
    expect(listed.priority, 5);

    // 3. unknown provider is a refusal with the engine's message, not "not supported".
    await expectLater(
        conn.run((c) => c.addKey(providerId: 'no-such-provider', name: 'x', secret: 's')),
        throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.rejected).having((e) => e.message, 'message', contains('Unknown provider'))));

    // 4. enable / disable
    await conn.run((c) => c.setKeyEnabled(id, false));
    expect(conn.state!.keys.firstWhere((k) => k.id == id).enabled, isFalse);
    await conn.run((c) => c.setKeyEnabled(id, true));
    expect(conn.state!.keys.firstWhere((k) => k.id == id).enabled, isTrue);

    // 5. key test: a real call to the (unreachable) upstream; the engine reports a status, flagged as a test.
    final t = await conn.run((c) => c.testKey(id));
    expect(t.message, startsWith('Key test: '));
    expect(t.data['test'], isTrue);

    // 6. circuit actions with provider/key coordinates
    var r = await conn.run((c) => c.circuitAction(level: 'provider', providerId: 'ollama', action: 'disable'));
    expect(r.ok, isTrue);
    expect(conn.state!.circuits.any((c) => c.id == 'ollama' && c.state == 'disabled'), isTrue);
    r = await conn.run((c) => c.circuitAction(level: 'provider', providerId: 'ollama', action: 'enable'));
    expect(r.ok, isTrue);
    r = await conn.run((c) => c.circuitAction(level: 'key', providerId: 'openai', keyId: id, action: 'reset'));
    expect(r.ok, isTrue);
    await expectLater(
        conn.run((c) => c.circuitAction(level: 'key', providerId: 'openai', action: 'reset')),
        throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.rejected).having((e) => e.message, 'message', contains('keyId'))));

    // 7. legacy migration end to end: engine confirms, old copy is deleted.
    final store = InMemorySecretsStore();
    await store.write('openai_api_key', 'sk-legacy-live-migrate-9876');
    final legacy = (await LegacyKeyMigration(store).scan()).single;
    final out = await LegacyKeyMigration(store).migrate(legacy, connection: conn, providerId: 'openai', name: 'migrated-live');
    expect(out.status, MigrationStatus.migrated, reason: out.message);
    expect(conn.state!.keys.any((k) => k.id == out.keyId && k.name == 'migrated-live'), isTrue);
    expect(await store.read('openai_api_key'), isNull);

    // 8. remove (and an unknown key is a refusal)
    for (final k in [id, out.keyId!]) {
      await conn.run((c) => c.removeKey(k));
      expect(conn.state!.keys.any((x) => x.id == k), isFalse);
    }
    await expectLater(conn.run((c) => c.removeKey('ghost')), throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.rejected)));
  }, skip: skipMgmt, timeout: const Timeout(Duration(seconds: 120)));
}
