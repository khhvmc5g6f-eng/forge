import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/engine_client.dart';
import 'package:forge/core/forge_engine/engine_connection.dart';
import 'package:forge/core/forge_engine/engine_credentials.dart';
import 'package:forge/core/forge_engine/engine_endpoint.dart';
import 'package:forge/core/security/secrets_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine_client_test.dart' show until;
import 'fake_engine.dart';

EngineConnection newConnection({EngineCredentialStore? credentials}) => EngineConnection(
      credentials: credentials,
      pollInterval: const Duration(milliseconds: 60),
      pollIntervalWithoutStream: const Duration(milliseconds: 40),
      minRefreshGap: const Duration(milliseconds: 10),
      backoff: (_) => const Duration(milliseconds: 40),
    );

void main() {
  var engine = FakeEngine();
  EngineConnection? conn;

  setUp(() {
    engine = FakeEngine();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    conn?.dispose();
    conn = null;
    await engine.stop();
  });

  EngineEndpoint ep() => EngineEndpoint(host: '127.0.0.1', port: engine.port);

  test('connects, polls state, opens the event stream', () async {
    await engine.start();
    conn = newConnection();
    expect(conn!.status, EngineLinkStatus.unconfigured);
    await conn!.configure(ep(), persist: false);
    await until(() => conn!.isConnected && conn!.eventsLive);
    expect(conn!.state!.keys, hasLength(2));
    expect(conn!.lastStateAt, isNotNull);
    await until(() => engine.stateHits >= 3, timeout: const Duration(seconds: 3)); // keeps polling
    expect(conn!.capabilitiesKnown, isTrue);
    expect(conn!.capabilities.readOnly, isTrue);
  });

  test('sends the bearer token; wrong token -> unauthorized and stops retrying', () async {
    await engine.start();
    engine.token = 'good';
    conn = newConnection();
    await conn!.configure(ep(), token: 'bad', persist: false);
    await until(() => conn!.status == EngineLinkStatus.unauthorized);
    final hits = engine.requestLog.length;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(engine.requestLog.length, hits, reason: 'no retry storm against a 401');
    expect(conn!.error, contains('401'));
    expect(conn!.state, isNull);

    await conn!.configure(ep(), token: 'good', persist: false);
    await until(() => conn!.isConnected);
  });

  test('engine down at start -> reconnecting with backoff, recovers when it comes up', () async {
    await engine.start();
    final port = engine.port;
    await engine.stop();
    conn = newConnection();
    await conn!.configure(EngineEndpoint(host: '127.0.0.1', port: port), persist: false);
    await until(() => conn!.status == EngineLinkStatus.reconnecting && conn!.retryAttempt >= 2);
    expect(conn!.state, isNull, reason: 'no data is shown for an engine we never reached');
    expect(conn!.nextRetryAt, isNotNull);
    engine = FakeEngine();
    await engine.start(port: port);
    await until(() => conn!.isConnected);
    expect(conn!.retryAttempt, 0);
    expect(conn!.error, isNull);
  });

  test('engine goes away -> stale data kept but flagged, then reconnects', () async {
    await engine.start();
    final port = engine.port;
    conn = newConnection();
    await conn!.configure(ep(), persist: false);
    await until(() => conn!.isConnected && conn!.eventsLive);
    await engine.stop();
    await until(() => conn!.status == EngineLinkStatus.reconnecting);
    expect(conn!.state, isNotNull);
    expect(conn!.isStale, isTrue);
    expect(conn!.eventsLive, isFalse);
    engine = FakeEngine();
    await engine.start(port: port);
    await until(() => conn!.isConnected && conn!.eventsLive);
    expect(conn!.isStale, isFalse);
  });

  test('events arrive in order, are deduped, and trigger a state refresh', () async {
    await engine.start();
    conn = newConnection();
    final seen = <int>[];
    await conn!.configure(ep(), persist: false);
    conn!.eventStream.listen((e) => seen.add(e.seq));
    await until(() => conn!.eventsLive);
    final hitsBefore = engine.stateHits;
    engine.state['totals'] = {'calls': 99, 'failures': 0, 'tokens': {}, 'cost': 0, 'estimatedRecords': 0};
    engine.emit('MODEL_REQUEST_COMPLETE', correlation: {'requestId': 'r1'});
    engine.emit('MODEL_REQUEST_COMPLETE', seq: 1, correlation: {'requestId': 'dup'}); // replayed seq is ignored
    engine.emit('TOOL_STARTED', seq: 2, data: {'tool': 'read_file'});
    await until(() => seen.length >= 2);
    expect(seen, [1, 2]);
    expect(conn!.events.map((e) => e.seq), [1, 2]);
    await until(() => conn!.state!.totals.calls == 99);
    expect(engine.stateHits, greaterThan(hitsBefore));
  });

  test('SSE reconnect resumes from last-event-id and reports missed events', () async {
    await engine.start();
    conn = newConnection();
    await conn!.configure(ep(), persist: false);
    await until(() => conn!.eventsLive);
    engine.emit('KEY_SELECTED', seq: 10);
    await until(() => conn!.events.length == 1);
    await engine.dropStreams();
    await until(() => engine.sseHeaders.length >= 2 && conn!.eventsLive);
    expect(engine.sseHeaders.last['last-event-id'], '10');
    engine.emit('KEY_SELECTED', seq: 15); // 11..14 were lost
    await until(() => conn!.events.length == 2);
    expect(conn!.missedEvents, 4);
  });

  test('engine restart (sequence goes backwards) resets the event log', () async {
    await engine.start();
    conn = newConnection();
    await conn!.configure(ep(), persist: false);
    await until(() => conn!.eventsLive);
    engine.emit('KEY_SELECTED', seq: 50);
    await until(() => conn!.events.length == 1);
    engine.state['lastEventSeq'] = 0;
    await until(() => conn!.events.isEmpty);
    engine.emit('KEY_SELECTED', seq: 1);
    await until(() => conn!.events.length == 1);
  });

  test('only NEW critical alerts are announced, never those already present on connect', () async {
    await engine.start();
    engine.state = FakeEngine.baseState(notifications: [FakeEngine.alert('old', 'critical')]);
    conn = newConnection();
    final crit = <String>[];
    conn!.criticalAlerts.listen((n) => crit.add(n.id));
    await conn!.configure(ep(), persist: false);
    await until(() => conn!.isConnected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(crit, isEmpty);
    engine.state = FakeEngine.baseState(notifications: [
      FakeEngine.alert('old', 'critical'),
      FakeEngine.alert('warn1', 'warning'),
      FakeEngine.alert('new', 'critical'),
      FakeEngine.alert('acked', 'critical', ack: true),
    ]);
    await until(() => crit.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(crit, ['new']);
  });

  test('actions run through the connection and refresh state; read-only engines refuse', () async {
    await engine.start();
    conn = newConnection();
    await conn!.configure(ep(), persist: false);
    await until(() => conn!.isConnected && conn!.capabilitiesKnown);
    await expectLater(conn!.run((c) => c.testKey('k1')), throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.notSupported)));

    engine.supportsActions = true;
    final hits = engine.stateHits;
    final r = await conn!.run((c) => c.circuitAction(level: 'key', id: 'openai/k2', action: 'reset'));
    expect(r.ok, isTrue);
    expect(engine.actions.single['body'], {'level': 'key', 'id': 'openai/k2', 'action': 'reset'});
    expect(engine.stateHits, greaterThan(hits));
  });

  test('address persists, token goes to the secure store only, restore reconnects', () async {
    await engine.start();
    final secrets = InMemorySecretsStore();
    final store = EngineCredentialStore(secrets: secrets);
    conn = newConnection(credentials: store);
    await conn!.configure(ep().copyWith(name: 'Test Mac'), token: 'tok-1');
    await until(() => conn!.isConnected);
    expect(await secrets.read('forge-engine.bearer-token'), 'tok-1');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().any((k) => (prefs.get(k)).toString().contains('tok-1')), isFalse, reason: 'token must not be in plain preferences');
    conn!.dispose();

    conn = newConnection(credentials: store);
    await conn!.restore();
    await until(() => conn!.isConnected);
    expect(conn!.endpoint!.name, 'Test Mac');
    expect(conn!.hasToken, isTrue);

    await conn!.forget();
    expect(conn!.status, EngineLinkStatus.unconfigured);
    expect(await secrets.read('forge-engine.bearer-token'), isNull);
    expect(await store.load(), isNull);
  });

  test('a secure store that refuses the token is reported, not hidden', () async {
    await engine.start();
    conn = newConnection(credentials: EngineCredentialStore(secrets: _FailingSecrets()));
    await conn!.configure(ep(), token: 't');
    expect(conn!.tokenNotPersisted, isTrue);
    await until(() => conn!.isConnected);
  });

  test('disconnect stops all traffic', () async {
    await engine.start();
    conn = newConnection();
    await conn!.configure(ep(), persist: false);
    await until(() => conn!.isConnected && conn!.eventsLive);
    await conn!.disconnect();
    expect(conn!.status, EngineLinkStatus.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final n = engine.requestLog.length;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(engine.requestLog.length, n);
  });
}

class _FailingSecrets implements SecretsStore {
  @override
  Future<void> write(String ref, String value) async => throw StateError('keychain denied');
  @override
  Future<String?> read(String ref) async => throw StateError('keychain denied');
  @override
  Future<void> delete(String ref) async => throw StateError('keychain denied');
  @override
  Future<List<String>> listRefs() async => const [];
}
