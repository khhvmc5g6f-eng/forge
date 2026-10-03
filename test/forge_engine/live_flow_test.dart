import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/engine_graph.dart';
import 'package:forge/core/forge_engine/engine_models.dart';
import 'package:forge/core/forge_engine/live_flow.dart';

import 'fake_engine.dart';

final t0 = DateTime(2026, 10, 3, 12);
int _seq = 0;

EngineEvent ev(String type, {String? rid, Map<String, dynamic> data = const {}, Map<String, dynamic> target = const {}, Map<String, dynamic> corr = const {}, DateTime? at}) =>
    EngineEvent(
      seq: ++_seq,
      ts: at ?? t0,
      type: type,
      correlation: {if (rid != null) 'requestId': rid, ...corr},
      target: target,
      data: data,
    );

const tgt = {'providerId': 'openai', 'keyId': 'k1', 'modelId': 'gpt-x'};

void main() {
  group('LiveFlowModel', () {
    test('idle until an event arrives; nothing animates on its own', () {
      final m = LiveFlowModel();
      expect(m.hasActivity, isFalse);
      expect(m.inFlight, isEmpty);
    });

    test('walks the stages of one streamed request from real events', () {
      final m = LiveFlowModel();
      m.ingest(ev('MODEL_REQUEST_STARTED', rid: 'r1', data: {'modelId': 'gpt-x'}, corr: {'agentId': 'coder'}), now: t0);
      expect(m.inFlight.single.stage, FlowStage.uploading);
      expect(m.inFlight.single.agentId, 'coder');
      m.ingest(ev('KEY_SELECTED', rid: 'r1', target: tgt), now: t0);
      expect(m.inFlight.single.stage, FlowStage.waiting);
      expect(m.inFlight.single.keyId, 'k1');
      m.ingest(ev('MODEL_FIRST_TOKEN', rid: 'r1', data: {'ttftMs': 310}), now: t0);
      expect(m.inFlight.single.stage, FlowStage.streaming);
      expect(m.inFlight.single.ttftMs, 310);
      m.ingest(ev('MODEL_TOKEN_USAGE', rid: 'r1', data: {'tokens': {'output': 42}}), now: t0);
      m.ingest(ev('MODEL_REQUEST_COMPLETE', rid: 'r1', data: {'latencyMs': 900}), now: t0);
      expect(m.inFlight, isEmpty);
      expect(m.hasActivity, isFalse);
      final done = m.recent.single;
      expect(done.stage, FlowStage.complete);
      expect(done.outputTokens, 42);
      expect(done.latencyMs, 900);
    });

    test('failover keeps the request alive and records the hop; retry is the next KEY_SELECTED', () {
      final m = LiveFlowModel();
      m.ingest(ev('MODEL_REQUEST_STARTED', rid: 'r', data: {'modelId': 'm'}), now: t0);
      m.ingest(ev('KEY_SELECTED', rid: 'r', target: tgt), now: t0);
      m.ingest(ev('MODEL_REQUEST_FAILED', rid: 'r', data: {'kind': 'rate_limit', 'status': 429}), now: t0);
      expect(m.inFlight.single.inFlight, isTrue, reason: 'a per-attempt failure is not the end');
      m.ingest(ev('FAILOVER', rid: 'r', data: {'from': 'work', 'toKey': 'spare', 'kind': 'rate_limit', 'status': 429}), now: t0);
      expect(m.inFlight.single.stage, FlowStage.retrying);
      expect(m.inFlight.single.failovers.single.toKey, 'spare');
      m.ingest(ev('KEY_SELECTED', rid: 'r', target: {...tgt, 'keyId': 'k2'}), now: t0);
      expect(m.inFlight.single.stage, FlowStage.waiting);
      expect(m.inFlight.single.attempts, 2);
      expect(m.inFlight.single.keyId, 'k2');
    });

    test('terminal failures end the request with their reason', () {
      final m = LiveFlowModel();
      m.ingest(ev('MODEL_REQUEST_STARTED', rid: 'r', data: {'modelId': 'm'}), now: t0);
      m.ingest(ev('MODEL_REQUEST_FAILED', rid: 'r', data: {'reason': 'attempts_exhausted', 'attempts': 3}), now: t0);
      expect(m.inFlight, isEmpty);
      expect(m.recent.single.stage, FlowStage.failed);
      expect(m.recent.single.failureReason, 'attempts_exhausted');
      // A guard refusal with no STARTED still shows up (as a failed request).
      m.ingest(ev('MODEL_REQUEST_FAILED', rid: 'g', data: {'reason': 'guard_blocked'}), now: t0);
      expect(m.recent.first.requestId, 'g');
    });

    test('replayed old history is never shown as in flight', () {
      final m = LiveFlowModel();
      final old = t0.subtract(const Duration(minutes: 10));
      m.ingest(ev('MODEL_REQUEST_STARTED', rid: 'old', data: {'modelId': 'm'}, at: old), now: t0);
      m.ingest(ev('TOOL_STARTED', data: {'tool': 'bash'}, corr: {'toolCallId': 'c'}, at: old), now: t0);
      expect(m.inFlight, isEmpty);
      expect(m.toolsInFlight, isEmpty);
      // Its replayed completion finishes it as a success, not as a made-up failure.
      m.ingest(ev('MODEL_REQUEST_COMPLETE', rid: 'old', data: {'latencyMs': 5}, at: old), now: t0);
      expect(m.recent.single.stage, FlowStage.complete);
      // A replayed request that never completed is eventually forgotten.
      m.ingest(ev('MODEL_REQUEST_STARTED', rid: 'old2', data: {'modelId': 'm'}, at: old), now: t0);
      expect(m.trackedCount, 1);
      m.reconcile({}, now: t0);
      expect(m.trackedCount, 0);
    });

    test('reconcile drops a request the engine no longer lists once past the grace period', () {
      final m = LiveFlowModel();
      m.ingest(ev('MODEL_REQUEST_STARTED', rid: 'lost', data: {'modelId': 'm'}), now: t0);
      m.reconcile({}, now: t0.add(const Duration(seconds: 5)));
      expect(m.inFlight, hasLength(1), reason: 'too young to judge');
      m.reconcile({}, now: t0.add(const Duration(seconds: 30)));
      expect(m.inFlight, isEmpty);
      m.ingest(ev('MODEL_REQUEST_STARTED', rid: 'live', data: {'modelId': 'm'}, at: t0.add(const Duration(seconds: 30))), now: t0.add(const Duration(seconds: 31)));
      m.reconcile({'live'}, now: t0.add(const Duration(minutes: 5)));
      expect(m.inFlight, hasLength(1), reason: 'the engine says it is still active');
    });

    test('tools start and finish', () {
      final m = LiveFlowModel();
      m.ingest(ev('TOOL_STARTED', data: {'tool': 'read_file'}, corr: {'toolCallId': 'c1', 'sessionId': 's'}), now: t0);
      expect(m.toolsInFlight.single.tool, 'read_file');
      m.ingest(ev('TOOL_FAILED', data: {'tool': 'read_file'}, corr: {'toolCallId': 'c1'}), now: t0);
      expect(m.toolsInFlight, isEmpty);
      expect(m.recentTools.single.failed, isTrue);
    });
  });

  group('EngineGraph', () {
    test('structure comes from state: providers, keys, models; no agents or tools invented', () {
      final g = EngineGraph()..applyState(EngineState.fromJson(FakeEngine.baseState()));
      expect(g.nodes.keys, containsAll(['provider:openai', 'provider:ollama', 'key:k1', 'key:k2', 'model:gpt-x']));
      expect(g.nodes.values.where((n) => n.kind == GraphNodeKind.agent || n.kind == GraphNodeKind.tool), isEmpty);
      expect(g.nodes['key:k2']!.state, 'open');
      expect(g.edges['key:k1>provider:openai']!.structural, isTrue);
      expect(g.edges['model:gpt-x>key:k1']!.structural, isTrue);
      expect(g.activeEdges(t0), isEmpty, reason: 'no event, no pulse');
    });

    test('a request lights agent->model->key->provider only from its events', () {
      final g = EngineGraph()..applyState(EngineState.fromJson(FakeEngine.baseState()));
      g.applyEvent(ev('MODEL_REQUEST_STARTED', rid: 'r', data: {'modelId': 'gpt-x'}, corr: {'agentId': 'coder'}, at: t0));
      expect(g.nodes.containsKey('agent:coder'), isTrue);
      expect(g.activeEdges(t0).map((e) => e.id), ['agent:coder>model:gpt-x']);
      g.applyEvent(ev('KEY_SELECTED', rid: 'r', target: tgt, at: t0));
      expect(g.activeEdges(t0).map((e) => e.id), containsAll(['model:gpt-x>key:k1', 'key:k1>provider:openai']));
      // Pulses fade: nothing is active after the window.
      expect(g.activeEdges(t0.add(EngineGraph.pulseWindow + const Duration(milliseconds: 1))), isEmpty);
      final e = g.edges['agent:coder>model:gpt-x']!;
      expect(g.pulseProgress(e, t0.add(const Duration(milliseconds: 1250))), closeTo(0.5, 0.001));
      expect(g.pulseProgress(e, t0.add(const Duration(seconds: 10))), isNull);
    });

    test('traffic without an agent id goes to one clearly labelled unattributed node', () {
      final g = EngineGraph();
      g.applyEvent(ev('MODEL_REQUEST_STARTED', rid: 'r', data: {'modelId': 'm'}, at: t0));
      expect(g.nodes[EngineGraph.unattributedAgent]!.label, 'Unattributed client');
    });

    test('failures pulse red; circuit transitions recolour the node', () {
      final g = EngineGraph()..applyState(EngineState.fromJson(FakeEngine.baseState()));
      g.applyEvent(ev('MODEL_REQUEST_FAILED', rid: 'r', target: tgt, data: {'kind': 'rate_limit'}, at: t0));
      expect(g.edges['key:k1>provider:openai']!.lastPulseFailed, isTrue);
      g.applyEvent(ev('CIRCUIT_STATE_CHANGED', target: tgt, data: {'level': 'key', 'id': 'openai/k1', 'to': 'open'}, at: t0));
      expect(g.nodes['key:k1']!.state, 'open');
    });

    test('tools attach to their agent', () {
      final g = EngineGraph();
      g.applyEvent(ev('TOOL_STARTED', data: {'tool': 'bash'}, corr: {'agentId': 'a1'}, at: t0));
      expect(g.nodes['tool:bash']!.kind, GraphNodeKind.tool);
      expect(g.activeEdges(t0).single.id, 'agent:a1>tool:bash');
    });

    test('layout puts agents left, providers right, all inside 0..1', () {
      final g = EngineGraph()..applyState(EngineState.fromJson(FakeEngine.baseState()));
      g.applyEvent(ev('MODEL_REQUEST_STARTED', rid: 'r', data: {'modelId': 'gpt-x'}, at: t0));
      expect(g.nodes[EngineGraph.unattributedAgent]!.x, lessThan(g.nodes['model:gpt-x']!.x));
      expect(g.nodes['model:gpt-x']!.x, lessThan(g.nodes['key:k1']!.x));
      expect(g.nodes['key:k1']!.x, lessThan(g.nodes['provider:openai']!.x));
      for (final n in g.nodes.values) {
        expect(n.x, inInclusiveRange(0, 1));
        expect(n.y, inInclusiveRange(0, 1));
      }
    });
  });
}
