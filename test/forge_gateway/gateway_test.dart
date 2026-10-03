import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_gateway/gateway_client.dart';
import 'package:forge/core/forge_gateway/gateway_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('state parses and keeps unknowns null', () {
    final s = GatewayState.fromJson({
      'providers': [
        {'id': 'p1', 'name': 'Ollama', 'kind': 'openai'}
      ],
      'keys': [
        {'id': 'k1', 'providerId': 'p1', 'masked': 'sk-…abcd', 'circuit': {'state': 'closed'}}
      ],
      'circuits': [{}],
      'lastEventSeq': 7,
    });
    expect(s.keys.single.healthScore, isNull);
    expect(s.keys.single.p50LatencyMs, isNull);
    expect(s.keys.single.circuitState, 'closed');
    expect(s.openCircuits, 1);
  });

  test('parses the real gateway key shape', () {
    final k = GatewayKey.fromJson({
      'id': 'k', 'providerId': 'p', 'circuit': {'state': 'open'},
      'health': {'score': 82.5}, 'last15m': {'calls': 4}, 'p50LatencyMs': 120,
    });
    expect(k.requests15m, 4);
    expect(k.healthScore, 82.5);
    expect(k.circuitState, 'open');
  });

  test('malformed events are rejected', () {
    expect(GatewayEvent.tryParse({'type': 'FAILOVER'}), isNull);
    expect(GatewayEvent.tryParse('x'), isNull);
    expect(GatewayEvent.tryParse({'seq': 1, 'ts': 5, 'type': 'FAILOVER'})!.type, 'FAILOVER');
  });

  test('connect polls state and reports connected', () async {
    final g = GatewayClient(clientFactory: () => MockClient.streaming((req, _) async {
          if (req.url.path == '/forge/state') {
            return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'keys': [], 'providers': []}))), 200);
          }
          return http.StreamedResponse(const Stream.empty(), 200);
        }));
    await g.connect('http://127.0.0.1:8765');
    expect(g.status, GatewayStatus.connected);
    await g.disconnect();
    expect(g.status, GatewayStatus.disconnected);
  });

  test('bad address and HTTP errors surface as errors', () async {
    final g = GatewayClient(clientFactory: () => MockClient((_) async => http.Response('no', 500)));
    await g.connect('nonsense');
    expect(g.status, GatewayStatus.error);
    await g.connect('http://127.0.0.1:1');
    expect(g.status, GatewayStatus.error);
    expect(g.error, contains('500'));
    await g.disconnect();
  });
}
