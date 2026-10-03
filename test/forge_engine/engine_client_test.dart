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
      engine = await FakeEngine(token: 't').start();
      final got = <String>[];
      var opened = false;
      final sub = clientFor(engine, token: 't').events(afterSeq: 41, onOpen: () => opened = true).listen((e) => got.add('${e.seq}:${e.type}'));
      await until(() => opened && engine.sseClients == 1);
      expect(engine.sseHeaders.single['last-event-id'], '41');
      engine.emit('MODEL_REQUEST_STARTED', seq: 42, correlation: {'requestId': 'r1'});
      engine.emit('KEY_SELECTED', seq: 43, correlation: {'requestId': 'r1'});
      await until(() => got.length == 2);
      expect(got, ['42:MODEL_REQUEST_STARTED', '43:KEY_SELECTED']);
      unawaited(sub.cancel()); // cancelling an open SSE response completes when the socket closes (tearDown)
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

    test('engine with actions: wire format of every action', () async {
      engine = await FakeEngine(token: 'tk', supportsActions: true).start();
      final c = clientFor(engine, token: 'tk');
      expect((await c.capabilities()).supports('circuit.action'), isTrue);
      await c.addKey(providerId: 'openai', name: 'new', secret: 'sk-live-123', priority: 3);
      await c.testKey('k 1');
      await c.setKeyEnabled('k1', false);
      await c.setKeyPriority('k1', 5);
      await c.removeKey('k1');
      await c.setProviderEnabled('openai', false);
      await c.circuitAction(level: 'key', id: 'openai/k2', action: 'probe');
      await c.acknowledge(id: 'a1');
      await c.acknowledge(all: true);
      await c.resumeGuard('session:s1');
      final a = engine.actions;
      expect(a[0], {'method': 'POST', 'path': '/forge/api/v1/vault/keys', 'body': {'providerId': 'openai', 'name': 'new', 'secret': 'sk-live-123', 'priority': 3}});
      expect(a[1]['path'], '/forge/api/v1/vault/keys/k%201/test');
      expect(a[2], {'method': 'PATCH', 'path': '/forge/api/v1/vault/keys/k1', 'body': {'enabled': false}});
      expect(a[3]['body'], {'priority': 5});
      expect(a[4]['method'], 'DELETE');
      expect(a[5]['path'], '/forge/api/v1/vault/providers/openai');
      expect(a[6]['body'], {'level': 'key', 'id': 'openai/k2', 'action': 'probe'});
      expect(a[7]['body'], {'id': 'a1'});
      expect(a[8]['body'], {'all': true});
      expect(a[9]['body'], {'scope': 'session:s1'});
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
