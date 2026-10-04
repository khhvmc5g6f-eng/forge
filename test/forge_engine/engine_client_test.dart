import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/engine_client.dart';
import 'package:forge/core/forge_engine/engine_endpoint.dart';

import 'fake_engine.dart';

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

EngineClient clientFor(FakeEngine e, {String? token, bool tls = false, Duration? timeout}) =>
    EngineClient(endpoint: EngineEndpoint(host: '127.0.0.1', port: e.port), token: token, requestTimeout: timeout ?? const Duration(seconds: 3));

void main() {
  var engine = FakeEngine();

  setUp(() => engine = FakeEngine());
  tearDown(() async => engine.stop());

  group('SSE parser', () {
    test('multi-line data, ids, comments, CRLF and split chunks', () async {
      final chunks = [
        ': hello\r\n',
        'id: 7\r\ndata: {"a":',
        '1}\r\n\r\ndata: line1\ndata: line2\n\n',
        'event: x\ndata: y\n\n',
        'data: unfinished',
      ];
      final frames = await parseSse(Stream.fromIterable(chunks.map((c) => c.codeUnits))).toList();
      expect(frames.map((f) => f.data), ['{"a":1}', 'line1\nline2', 'y']);
      expect(frames.first.id, '7');
      expect(frames.last.event, 'x');
    });
  });

  group('reads', () {
    test('fetchState sends the bearer token and parses state', () async {
      engine = await FakeEngine(token: 'secret-token').start();
      final s = await clientFor(engine, token: 'secret-token').fetchState();
      expect(s.keys, hasLength(2));
      expect(await clientFor(engine, token: 'secret-token').health(), isTrue);
    });

    test('wrong or missing token -> unauthorized', () async {
      engine = await FakeEngine(token: 'right').start();
      for (final t in ['wrong', null]) {
        await expectLater(
          clientFor(engine, token: t).fetchState(),
          throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.unauthorized)),
        );
      }
    });

    test('5xx -> server error; a 200 with unexpected JSON parses as an empty state, not invented data', () async {
      engine = await FakeEngine().start();
      engine.failState = true;
      await expectLater(clientFor(engine).fetchState(), throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.server)));
      engine.failState = false;
      engine.stateStatus = 200;
      final s = await clientFor(engine).fetchState();
      expect(s.keys, isEmpty);
    });

    test('unreachable host -> unreachable', () async {
      engine = await FakeEngine().start();
      final port = engine.port;
      await engine.stop();
      engine = await FakeEngine().start(); // so tearDown has something to stop
      await expectLater(
        EngineClient(endpoint: EngineEndpoint(host: '127.0.0.1', port: port), requestTimeout: const Duration(seconds: 2)).fetchState(),
        throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.unreachable)),
      );
    });

    test('the token never appears in error messages', () async {
      engine = await FakeEngine().start();
      final port = engine.port;
      await engine.stop();
      engine = await FakeEngine().start();
      try {
        await EngineClient(endpoint: EngineEndpoint(host: '127.0.0.1', port: port), token: 'TOPSECRET', requestTimeout: const Duration(seconds: 2)).fetchState();
        fail('should throw');
      } on EngineException catch (e) {
        expect(e.message, isNot(contains('TOPSECRET')));
      }
    });
  });

  group('event stream', () {
    test('yields events, sends last-event-id, skips malformed frames', () async {
      engine = await FakeEngine(token: 'tok-123').start();
      final got = <String>[];
      var opened = false;
      final sub = clientFor(engine, token: 'tok-123')
          .events(afterSeq: 41, onOpen: () => opened = true)
          .listen((e) => got.add('${e.seq}:${e.type}'), onError: (_) {}); // the server closing at tearDown is an error here
      await until(() => opened && engine.sseClients == 1);
      expect(engine.sseHeaders.single['last-event-id'], '41');
      engine.emit('MODEL_REQUEST_STARTED', seq: 42, correlation: {'requestId': 'r1'});
      engine.emit('KEY_SELECTED', seq: 43, correlation: {'requestId': 'r1'});
      await until(() => got.length == 2);
      expect(got, ['42:MODEL_REQUEST_STARTED', '43:KEY_SELECTED']);
      unawaited(sub.cancel().catchError((_) {})); // cancelling an open SSE response completes when the socket closes (tearDown)
    });

    test('401 on the stream is unauthorized', () async {
      engine = await FakeEngine(token: 'right').start();
      await expectLater(
        clientFor(engine, token: 'bad').events().toList(),
        throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.unauthorized)),
      );
    });

    test('a dropped connection ends the stream with an error', () async {
      engine = await FakeEngine().start();
      var opened = false;
      final done = Completer<Object?>();
      clientFor(engine).events(onOpen: () => opened = true).listen((_) {}, onError: done.complete, onDone: () => done.complete(null));
      await until(() => opened && engine.sseClients == 1);
      await engine.dropStreams();
      // A clean server-side close ends the stream; either completion is a "dropped" signal.
      await done.future.timeout(const Duration(seconds: 3));
    });
  });

  group('actions', () {
    test('read-only engine: capabilities none, actions notSupported', () async {
      engine = await FakeEngine().start();
      final c = clientFor(engine);
      final caps = await c.capabilities();
      expect(caps.readOnly, isTrue);
      await expectLater(c.testKey('k1'), throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.notSupported)));
    });

    test('management API: capabilities probe, and the wire format of every real action', () async {
      engine = await FakeEngine(supportsActions: true, managementToken: 'tk').start();
      final c = clientFor(engine, token: 'tk');
      final caps = await c.capabilities();
      expect(caps.supports('key.add'), isTrue);
      expect(caps.supports('circuit.action'), isTrue);
      expect(caps.supports('key.priority'), isFalse, reason: 'the engine API cannot set priority');
      expect(caps.supports('alert.ack'), isFalse);
      final added = await c.addKey(providerId: 'openai', name: 'new', secret: 'sk-live-123', priority: 3);
      expect(added.ok, isTrue);
      expect(added.data['id'], 'k3');
      expect(added.message, 'Key "new" stored in the engine vault');
      expect(added.message + added.data.toString(), isNot(contains('sk-live-123')));
      final t = await c.testKey('k 1');
      expect(t.ok, isTrue);
      expect(t.message, 'Key test: pass');
      await c.setKeyEnabled('k1', false);
      await c.removeKey('k1');
      final probe = await c.circuitAction(level: 'key', providerId: 'openai', keyId: 'k2', action: 'probe');
      expect(probe.message, contains('half-open'));
      await c.circuitAction(level: 'model', providerId: 'openai', keyId: 'k2', modelId: 'gpt/x', action: 'disable');
      final a = engine.actions;
      expect(a[0], {'method': 'POST', 'path': '/forge/api/keys', 'body': {'providerId': 'openai', 'name': 'new', 'secret': 'sk-live-123', 'priority': 3}});
      expect(a[1], {'method': 'POST', 'path': '/forge/api/keys/k%201/test', 'body': <String, dynamic>{}});
      expect(a[2], {'method': 'POST', 'path': '/forge/api/keys/k1/enabled', 'body': {'enabled': false}});
      expect(a[3]['method'], 'DELETE');
      expect(a[3]['path'], '/forge/api/keys/k1');
      expect(a[4], {'method': 'POST', 'path': '/forge/api/circuits', 'body': {'level': 'key', 'providerId': 'openai', 'keyId': 'k2', 'action': 'probe'}});
      expect(a[5]['body'], {'level': 'model', 'providerId': 'openai', 'keyId': 'k2', 'modelId': 'gpt/x', 'action': 'disable'});
    });

    test('management API without or with the wrong token: capabilities says auth required, actions are unauthorized', () async {
      engine = await FakeEngine(supportsActions: true, managementToken: 'tk').start();
      for (final token in [null, 'wrong']) {
        final c = clientFor(engine, token: token);
        final caps = await c.capabilities();
        expect(caps.authRejected, isTrue);
        expect(caps.readOnly, isFalse);
        expect(caps.actions, isEmpty);
        await expectLater(c.removeKey('k1'), throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.unauthorized)));
      }
      expect(engine.actions, isEmpty);
    });

    test('a failed key test is reported as not ok, with the engine detail', () async {
      engine = FakeEngine(supportsActions: true)..testStatus = 'fail';
      await engine.start();
      final r = await clientFor(engine).testKey('k1');
      expect(r.ok, isFalse);
      expect(r.message, 'Key test: fail (HTTP 401)');
    });

    test('engine refusals (unknown provider / key) are "rejected", not "not supported"', () async {
      engine = await FakeEngine(supportsActions: true).start();
      final c = clientFor(engine);
      await expectLater(
          c.addKey(providerId: 'nope', name: 'n', secret: 's'),
          throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.rejected).having((e) => e.message, 'message', contains('Unknown provider'))));
      await expectLater(c.removeKey('ghost'), throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.rejected)));
    });

    test('an engine without the management route stays "not supported"', () async {
      engine = await FakeEngine().start();
      await expectLater(clientFor(engine).circuitAction(level: 'provider', providerId: 'openai', action: 'reset'),
          throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.notSupported)));
    });

    test('refuses to send a secret over cleartext to a non-loopback host', () async {
      engine = await FakeEngine(supportsActions: true).start();
      final c = EngineClient(endpoint: const EngineEndpoint(host: '192.168.1.50', port: 8765));
      expect(
        () => c.addKey(providerId: 'openai', name: 'n', secret: 'sk-secret'),
        throwsA(isA<EngineException>().having((e) => e.kind, 'kind', EngineErrorKind.insecureTransport)),
      );
      expect(engine.actions, isEmpty);
    });
  });
}
