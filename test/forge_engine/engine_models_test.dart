import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/engine_models.dart';

import 'fake_engine.dart';

void main() {
  test('parses a full state snapshot', () {
    final s = EngineState.fromJson(FakeEngine.baseState(notifications: [FakeEngine.alert('a1', 'critical')]));
    expect(s.providers.map((p) => p.id), ['openai', 'ollama']);
    expect(s.keys, hasLength(2));
    final k = s.keyById('k1')!;
    expect(k.masked, 'sk-…abcd');
    expect(k.circuitState, 'closed');
    expect(k.health!.score, 88.5);
    expect(k.capacity!.worst, 'warning');
    expect(k.capacity!.providerQuotaKnown, isFalse);
    expect(k.capacity!.limits.single.fraction, 0.9);
    expect(k.last15m!.costCurrency, 'USD');
    expect(k.p95LatencyMs, 1800);
    expect(k.canServe, isTrue);
    expect(s.keyById('k2')!.canServe, isFalse, reason: 'open circuit does not serve');
    expect(s.servableKeys, 1);
    expect(s.circuits.single.blocksTraffic, isTrue);
    expect(s.totals.calls, 20);
    expect(s.totals.failureRate, 0.05);
    expect(s.totalsAllTime.hasCost, isFalse, reason: 'no currency means unpriced');
    expect(s.guard.single.level, 'throttle');
    expect(s.guard.single.tokensIncreasePct, 400);
    expect(s.guard.single.needsAttention, isTrue);
    expect(s.routing.policy, 'priority');
    expect(s.routing.failoversUsed, 1);
    expect(s.routing.recentDecisions.single.chosen!.keyId, 'k1');
    expect(s.routing.recentDecisions.single.rejected.single.reason, 'circuit open');
    expect(s.notifications.single.isCritical, isTrue);
    expect(s.unreadNotifications, 1);
    expect(s.availability.single.status, 'available');
    expect(s.analytics.written, 200);
  });

  test('missing fields stay unknown instead of becoming numbers', () {
    final s = EngineState.fromJson({
      'keys': [
        {'id': 'k', 'providerId': 'p'}
      ],
    });
    final k = s.keys.single;
    expect(k.health, isNull);
    expect(k.capacity, isNull);
    expect(k.last15m, isNull);
    expect(k.p50LatencyMs, isNull);
    expect(k.circuit, isNull);
    expect(k.circuitState, 'unknown');
    expect(s.routing.policy, isNull);
    expect(s.guard, isEmpty);
  });

  test('health without measurements has a null score', () {
    final h = EngineHealth.fromJson({'score': null, 'factors': [], 'sampleSize': 0});
    expect(h.score, isNull);
  });

  test('garbage types are ignored, not thrown', () {
    final s = EngineState.fromJson({'keys': 'nope', 'providers': [1, 'x', null], 'totals': [], 'guard': {}});
    expect(s.keys, isEmpty);
    expect(s.providers, isEmpty);
    expect(s.totals.calls, 0);
  });

  test('events: well formed vs malformed', () {
    expect(EngineEvent.tryParse({'type': 'FAILOVER'}), isNull);
    expect(EngineEvent.tryParse('x'), isNull);
    final e = EngineEvent.tryParse({
      'seq': 3,
      'ts': 5,
      'type': 'KEY_SELECTED',
      'correlation': {'requestId': 'r', 'agentId': 'a'},
      'target': {'providerId': 'p', 'keyId': 'k', 'modelId': 'm'},
      'data': {'why': 'x'},
    })!;
    expect(e.requestId, 'r');
    expect(e.agentId, 'a');
    expect(e.keyId, 'k');
    expect(e.data['why'], 'x');
  });

  test('routing decision knows when it failed over', () {
    final d = EngineRoutingDecision.fromJson({
      'requestId': 'r',
      'ts': 1,
      'policy': 'p',
      'requestedModel': 'm',
      'attempts': [
        {'target': {'providerId': 'p', 'keyId': 'a', 'modelId': 'm'}, 'rank': 1, 'why': '', 'step': 'preferred'},
        {'target': {'providerId': 'p', 'keyId': 'b', 'modelId': 'm'}, 'rank': 2, 'why': '', 'step': 'equivalent'},
      ],
    });
    expect(d.failedOver, isTrue);
  });
}
