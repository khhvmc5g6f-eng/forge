import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';
import 'package:forge/ui/engine/alert_bridge.dart';
import 'package:forge/ui/engine/engine_console.dart';
import 'package:forge/ui/engine/live_flow_page.dart';
import 'package:forge/ui/panels/neural_lab/forge_neural_lab.dart';

import '../../forge_engine/fake_engine.dart';
import 'harness.dart';

int _seq = 0;
final clock = FakeClock();
EngineEvent ev(String type, {String? rid, Map<String, dynamic> data = const {}, Map<String, dynamic> target = const {}, Map<String, dynamic> corr = const {}}) => EngineEvent(
      seq: ++_seq,
      ts: clock(),
      type: type,
      correlation: {'requestId': ?rid, ...corr},
      target: target,
      data: data,
    );

const tgt = {'providerId': 'openai', 'keyId': 'k1', 'modelId': 'gpt-x'};

void main() {
  group('Live Flow', () {
    testWidgets('idle: static, no animation, says nothing is running', (tester) async {
      await pumpWithSize(tester, const LiveFlowPage(), size: desktop);
      expect(find.text('Idle: nothing in flight'), findsOneWidget);
      expect(find.textContaining('Nothing is running'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.hasRunningAnimations, isFalse, reason: 'an idle engine must produce no motion');
    });

    testWidgets('animates only while a real request is in flight, then stops', (tester) async {
      final conn = StubConnection();
      await pumpWithSize(tester, const LiveFlowPage(), conn: conn, size: phone, clock: clock);
      conn.debugEmit(ev('MODEL_REQUEST_STARTED', rid: 'r1', data: {'modelId': 'gpt-x'}, corr: {'agentId': 'coder'}));
      await tester.pump();
      await tester.pump();
      expect(find.text('gpt-x'), findsWidgets);
      expect(find.textContaining('agent coder'), findsOneWidget);
      expect(find.text('Uploading'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      expect(tester.hasRunningAnimations, isTrue);

      conn.debugEmit(ev('KEY_SELECTED', rid: 'r1', target: tgt));
      await tester.pump();
      conn.debugEmit(ev('MODEL_FIRST_TOKEN', rid: 'r1', target: tgt, data: {'ttftMs': 250}));
      await tester.pump();
      expect(find.textContaining('first token 250 ms'), findsWidgets);

      conn.debugEmit(ev('FAILOVER', rid: 'r1', data: {'from': 'work', 'toKey': 'spare', 'kind': 'rate_limit', 'status': 429}));
      await tester.pump();
      expect(find.textContaining('Failover: work failed (rate limit 429) → spare'), findsOneWidget);
      expect(find.text('Retrying on the next candidate…'), findsOneWidget);

      conn.debugEmit(ev('MODEL_REQUEST_COMPLETE', rid: 'r1', data: {'latencyMs': 900}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Idle: nothing in flight'), findsOneWidget);
      expect(find.textContaining('complete'), findsWidgets, reason: 'it moves to Recently finished');
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('without the event stream it says it cannot see requests', (tester) async {
      await pumpWithSize(tester, const LiveFlowPage(), conn: StubConnection(eventsLive: false));
      expect(find.text('EVENT STREAM NOT OPEN'), findsOneWidget);
      expect(find.textContaining('will not guess'), findsOneWidget);
    });
  });

  group('Neural Lab network', () {
    testWidgets('default mode is the live Forge network; the MLP demo is labelled local', (tester) async {
      await pumpWithSize(tester, const NeuralLabPanel(), size: desktop);
      expect(find.text('Forge network (live)'), findsOneWidget);
      expect(find.textContaining('Idle: edges light up only when the engine reports traffic'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.tap(find.text('Local MLP experiment'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('LOCAL EXPERIMENT'), findsOneWidget);
    });

    testWidgets('edges light only after an event, then go idle again', (tester) async {
      final conn = StubConnection();
      await pumpWithSize(tester, const NeuralLabPanel(), conn: conn, size: desktop, clock: clock);
      expect(find.textContaining('active edge'), findsNothing);
      conn.debugEmit(ev('MODEL_REQUEST_STARTED', rid: 'r', data: {'modelId': 'gpt-x'}, corr: {'agentId': 'coder'}));
      await tester.pump();
      await clock.elapse(tester, const Duration(milliseconds: 100));
      expect(find.textContaining('active edge'), findsOneWidget);
      expect(tester.hasRunningAnimations, isTrue);
      await clock.elapse(tester, const Duration(seconds: 4));
      await clock.elapse(tester, const Duration(milliseconds: 100));
      expect(find.textContaining('Idle: edges light up'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('no engine: says so, invents no nodes', (tester) async {
      final c = EngineConnection(); // unconfigured, no state
      await pumpWithSize(tester, const NeuralLabPanel(), conn: StubConnection(stateJson: const {}, actions: false)..state = c.state);
      expect(find.textContaining('Connect to an engine to see its network'), findsOneWidget);
    });
  });

  group('Console shell', () {
    testWidgets('phone: bottom bar with More; tablet/desktop: rail with every page', (tester) async {
      await pumpWithSize(tester, const EngineConsole(), size: phone);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      for (final l in ['Usage', 'Live Flow', 'Network', 'Connection']) {
        expect(find.descendant(of: sheet, matching: find.text(l)), findsOneWidget);
      }
      await tester.tap(find.descendant(of: sheet, matching: find.text('Usage')));
      await tester.pumpAndSettle();
      expect(find.text('Last 15 minutes'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await pumpWithSize(tester, const EngineConsole(), size: tablet);
      expect(find.byType(NavigationRail), findsOneWidget);
      await pumpWithSize(tester, const EngineConsole(), size: desktop);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('Live Flow'), findsOneWidget);
    });

    testWidgets('offline banner is honest and links to Connection', (tester) async {
      final conn = StubConnection(status: EngineLinkStatus.reconnecting)
        ..retryAttempt = 3
        ..error = 'Cannot reach the engine: refused';
      await pumpWithSize(tester, const EngineConsole(), conn: conn, size: desktop);
      expect(find.textContaining('is not answering'), findsOneWidget);
      expect(find.textContaining('may be out of date'), findsOneWidget);
      await tester.tap(find.textContaining('is not answering'));
      await tester.pumpAndSettle();
      expect(find.text('Engine connection'), findsOneWidget);
    });

    testWidgets('unread alerts show a badge on Alerts', (tester) async {
      final conn = StubConnection(stateJson: FakeEngine.baseState(notifications: [FakeEngine.alert('a', 'critical'), FakeEngine.alert('b', 'warning')]));
      await pumpWithSize(tester, const EngineConsole(), conn: conn, size: phone);
      expect(find.text('2'), findsOneWidget);
    });
  });

  group('Alert bridge', () {
    testWidgets('a NEW critical alert raises a local notification; old ones and warnings do not; toggle off silences', (tester) async {
      final conn = StubConnection(stateJson: FakeEngine.baseState(notifications: [FakeEngine.alert('old', 'critical')]));
      final rec = RecordingAlertNotifier();
      tester.view.physicalSize = desktop;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late WidgetRef cap;
      await tester.pumpWidget(ProviderScope(
        overrides: [engineConnectionProvider.overrideWith((ref) => conn), alertNotifierProvider.overrideWithValue(rec)],
        child: MaterialApp(
          home: EngineAlertBridge(
            autoRestore: false,
            child: Consumer(builder: (c, ref, _) {
              cap = ref;
              return const SizedBox();
            }),
          ),
        ),
      ));
      await tester.pump();
      expect(rec.shown, isEmpty);
      final j = FakeEngine.baseState(notifications: [FakeEngine.alert('old', 'critical'), FakeEngine.alert('w', 'warning'), FakeEngine.alert('new', 'critical')]);
      conn.debugApply(state: EngineState.fromJson(j));
      await tester.pump();
      expect(rec.shown.map((n) => n.id), ['new']);

      cap.read(criticalNotificationsEnabledProvider.notifier).state = false;
      j['notifications'] = {'unread': 3, 'recent': [...(j['notifications'] as Map)['recent'] as List, FakeEngine.alert('newer', 'critical')]};
      conn.debugApply(state: EngineState.fromJson(j));
      await tester.pump();
      expect(rec.shown.map((n) => n.id), ['new']);
    });
  });
}
