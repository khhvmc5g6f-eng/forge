import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';
import 'package:forge/ui/engine/alerts_page.dart';
import 'package:forge/ui/engine/circuits_page.dart';
import 'package:forge/ui/engine/connect_page.dart';
import 'package:forge/ui/engine/dashboard_page.dart';
import 'package:forge/ui/engine/usage_page.dart';
import 'package:forge/ui/engine/vault_page.dart';
import 'package:forge/ui/settings/settings_nav.dart';

import '../../forge_engine/fake_engine.dart';
import 'harness.dart';

void main() {
  group('Dashboard', () {
    testWidgets('answers the control-centre questions from engine state (phone)', (tester) async {
      final conn = StubConnection(stateJson: FakeEngine.baseState(notifications: [FakeEngine.alert('a1', 'critical')]));
      await pumpWithSize(tester, const DashboardPage(), conn: conn, size: phone);
      expect(find.text('Can Forge serve requests right now?'), findsOneWidget);
      expect(find.text('DEGRADED'), findsOneWidget);
      expect(find.text('1 of 2 keys'), findsOneWidget);
      expect(find.text('What is running now?'), findsOneWidget);
      expect(find.text('Idle. No model calls or tools in flight.'), findsOneWidget);
      // attention: the open circuit and the critical alert, nothing invented
      expect(find.text('Key spare circuit open'), findsOneWidget);
      expect(find.text('Key work at 96% of tokensPerDay'), findsOneWidget);
      // usage: priced 15-minute window, unpriced all-time window is not shown as $0
      expect(find.text(r'$0.5000'), findsOneWidget);
      expect(find.textContaining('All time: 200 calls'), findsOneWidget);
      expect(find.textContaining('unpriced'), findsWidgets);
      expect(find.text('2 call(s) estimated'), findsOneWidget);
      expect(find.text('HEALTHY'), findsOneWidget);
      expect(find.text('Engine memory: 40 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lays out on tablet and desktop without overflow', (tester) async {
      for (final size in [tablet, desktop]) {
        await pumpWithSize(tester, const DashboardPage(), size: size);
        expect(find.text('Routing'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('no engine data: says so instead of showing numbers', (tester) async {
      final conn = EngineConnection()..debugApply(status: EngineLinkStatus.reconnecting, error: 'Cannot reach the engine');
      await pumpWithSize(tester, const DashboardPage(), conn: _wrap(conn));
      expect(find.text('Engine unreachable'), findsOneWidget);
      expect(find.textContaining('nothing is shown'), findsOneWidget);
      expect(find.text('Usage'), findsNothing);
    });

    test('attentionItems ranks critical first and is empty for a healthy engine', () {
      final healthy = EngineState.fromJson({
        'providers': [
          {'id': 'p', 'name': 'P', 'enabled': true}
        ],
        'keys': [
          {'id': 'k', 'providerId': 'p', 'enabled': true, 'circuit': {'id': 'p/k', 'level': 'key', 'state': 'closed'}}
        ],
      });
      expect(attentionItems(healthy), isEmpty);
      expect(servingVerdict(healthy).verdict, 'Yes');
      final bad = EngineState.fromJson(FakeEngine.baseState(notifications: [FakeEngine.alert('w', 'warning'), FakeEngine.alert('c', 'critical')]));
      final items = attentionItems(bad);
      expect(items.first.severity, 'critical');
      expect(items.map((i) => i.severity), isNot(contains('nonsense')));
      expect(servingVerdict(EngineState.fromJson({'keys': []})).verdict, 'No keys');
    });
  });

  group('Vault', () {
    testWidgets('lists providers and masked keys, never a secret', (tester) async {
      await pumpWithSize(tester, const VaultPage(), size: phone);
      expect(find.text('OpenAI'), findsOneWidget);
      expect(find.textContaining('sk-…abcd'), findsOneWidget);
      expect(find.text('OPEN'), findsOneWidget);
      expect(find.text('CLOSED'), findsOneWidget);
      expect(find.textContaining('Health 89'), findsOneWidget);
      expect(find.textContaining('No limits configured'), findsOneWidget);
    });

    testWidgets('read-only engine: every mutation is disabled with the reason', (tester) async {
      final conn = StubConnection(actions: false);
      await pumpWithSize(tester, const VaultPage(), conn: conn);
      expect(find.textContaining('read-only'), findsWidgets);
      final add = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add key'));
      expect(add.onPressed, isNull);
      final test = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Test').first);
      expect(test.onPressed, isNull);
    });

    testWidgets('priority and provider switches are disabled with the engine-API reason; key controls the API supports are enabled', (tester) async {
      await pumpWithSize(tester, const VaultPage(), conn: StubConnection(), size: desktop);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Priority').first).onPressed, isNull);
      expect(tester.widget<Switch>(find.byType(Switch).first).onChanged, isNull, reason: 'provider enable needs a full provider definition');
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Test').first).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add key')).onPressed, isNotNull);
    });

    testWidgets('management API needs the token: every action is disabled and says so', (tester) async {
      final conn = StubConnection(actions: false)..debugApply(capabilities: EngineCapabilities.authRequired);
      await pumpWithSize(tester, const VaultPage(), conn: conn);
      expect(find.textContaining('needs the bearer token'), findsWidgets);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add key')).onPressed, isNull);
    });

    testWidgets('add key: masked field, sent once, secret never rendered afterwards', (tester) async {
      final conn = StubConnection();
      await pumpWithSize(tester, const VaultPage(), conn: conn, size: desktop);
      await tester.tap(find.widgetWithText(FilledButton, 'Add key'));
      await tester.pumpAndSettle();
      final secretField = find.widgetWithText(TextField, 'API key');
      expect(tester.widget<TextField>(secretField).obscureText, isTrue);
      await tester.enterText(find.widgetWithText(TextField, 'Name (e.g. work, spare)'), 'fresh');
      await tester.enterText(secretField, 'sk-super-secret-9999');
      await tester.enterText(find.widgetWithText(TextField, 'Priority (optional, lower = first)'), '4');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Add key').last);
      await tester.pumpAndSettle();
      expect(conn.actionLog, ['addKey openai fresh sk-super-secret-9999 4']);
      expect(find.textContaining('sk-super-secret-9999'), findsNothing);
    });

    testWidgets('add key is blocked over unencrypted LAN HTTP', (tester) async {
      final conn = StubConnection(endpoint: const EngineEndpoint(host: '192.168.1.20', port: 8765));
      await pumpWithSize(tester, const VaultPage(), conn: conn, size: desktop);
      expect(find.textContaining('unencrypted HTTP'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Add key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name (e.g. work, spare)'), 'x');
      await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-1');
      await tester.pump();
      final submit = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add key').last);
      expect(submit.onPressed, isNull);
      expect(find.text('Disabled: this connection is not encrypted.'), findsOneWidget);
    });

    testWidgets('test, remove and enable go through confirmations and the engine', (tester) async {
      final conn = StubConnection();
      await pumpWithSize(tester, const VaultPage(), conn: conn, size: desktop);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('real request'), findsOneWidget);
      await tester.tap(find.text('Run test'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(conn.actionLog, ['testKey k1'], reason: 'cancelled removal must not reach the engine');
      await tester.tap(find.widgetWithText(TextButton, 'Remove').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(conn.actionLog.last, 'removeKey k1');
    });
  });

  group('Circuits', () {
    test('tree puts keys under providers and models under keys; orphans kept', () {
      final j = FakeEngine.baseState();
      (j['circuits'] as List).add({'id': 'openai/k1/gpt-x', 'level': 'model', 'state': 'cooldown', 'trips': 2});
      (j['circuits'] as List).add({'id': 'gone/kx', 'level': 'key', 'state': 'open'});
      final t = buildCircuitTree(EngineState.fromJson(j));
      final openai = t.tree.firstWhere((n) => n.id == 'openai');
      expect(openai.children.map((k) => k.label), ['work', 'spare']);
      expect(openai.children.first.children.single.label, 'gpt-x');
      expect(openai.children.first.children.single.state, 'cooldown');
      expect(t.tree.firstWhere((n) => n.id == 'ollama').state, 'closed');
      expect(t.orphans.single.id, 'gone/kx');
    });

    test('orphan circuits recover provider, key and a slash-containing model id', () {
      final n = orphanNode(EngineCircuit.fromJson({'id': 'p/k/meta/llama-3', 'level': 'model', 'state': 'open'}));
      expect((n.providerId, n.keyId, n.modelId), ('p', 'k', 'meta/llama-3'));
      expect((orphanNode(EngineCircuit.fromJson({'id': 'p', 'level': 'provider', 'state': 'open'})).keyId), isNull);
    });

    testWidgets('key-level circuit action sends provider and key coordinates, not the joined id', (tester) async {
      final conn = StubConnection();
      await pumpWithSize(tester, const CircuitsPage(), conn: conn, size: desktop);
      // spare (k2) is open: its row has Probe now
      await tester.tap(find.widgetWithText(TextButton, 'Probe now'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Probe'));
      await tester.pumpAndSettle();
      expect(conn.actionLog.single, 'circuit key openai k2 - probe');
    });

    testWidgets('disable asks first, then acts; probe and reset available on an open circuit', (tester) async {
      final conn = StubConnection();
      await pumpWithSize(tester, const CircuitsPage(), conn: conn, size: desktop);
      expect(find.text('spare (key)'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Probe now'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Disable').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('No traffic will be routed'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Disable'));
      await tester.pumpAndSettle();
      // provider circuit (first card): level provider, provider id, no key, no model
      expect(conn.actionLog.single, 'circuit provider openai - - disable');
      await tester.tap(find.widgetWithText(TextButton, 'Reset').first);
      await tester.pumpAndSettle();
      expect(conn.actionLog.last, 'circuit provider openai - - reset');
      expect(tester.takeException(), isNull);
    });

    testWidgets('read-only engine disables circuit controls', (tester) async {
      await pumpWithSize(tester, const CircuitsPage(), conn: StubConnection(actions: false), size: phone);
      for (final b in tester.widgetList<TextButton>(find.byType(TextButton))) {
        expect(b.onPressed, isNull);
      }
      expect(find.textContaining('read-only'), findsOneWidget);
    });
  });

  group('Usage', () {
    testWidgets('capacity with its provenance, provider quota unknown, unpriced cost, budgets gap stated', (tester) async {
      await pumpWithSize(tester, const UsagePage(), size: const Size(390, 2600));
      expect(find.textContaining('Provider quota: Unknown'), findsOneWidget);
      expect(find.text('tokensPerDay'), findsOneWidget);
      expect(find.textContaining('90 / 100'), findsOneWidget);
      expect(find.text('warning · user configured'), findsOneWidget);
      expect(find.text('unpriced'), findsOneWidget);
      expect(find.textContaining('not part of /forge/state'), findsOneWidget);
      expect(find.textContaining('No limits configured for this key'), findsOneWidget);
    });
  });

  group('Alerts', () {
    testWidgets('lists alerts; acknowledge and resume stay disabled with the engine-API reason; notification settings are a deep link', (tester) async {
      final conn = StubConnection(stateJson: FakeEngine.baseState(notifications: [FakeEngine.alert('a1', 'critical'), FakeEngine.alert('a2', 'warning', ack: true)]));
      await pumpWithSize(tester, const AlertsPage(), conn: conn, size: desktop);
      expect(find.text('1 unacknowledged of 2'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Acknowledge all')).onPressed, isNull);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.check)).onPressed, isNull);
      expect(find.textContaining('no alert acknowledgement endpoint'), findsOneWidget);
      expect(find.byType(Switch), findsNothing, reason: 'the notification preference is a setting, edited in Settings');
      final container = ProviderScope.containerOf(tester.element(find.byType(AlertsPage)));
      await tester.tap(find.text('Notification settings'));
      await tester.pump();
      expect(container.read(settingsSectionProvider), SettingsSection.notifications);
      expect(conn.actionLog, isEmpty);
    });

    testWidgets('guard scope shows burn vs baseline; resume is disabled with its reason', (tester) async {
      final conn = StubConnection();
      await pumpWithSize(tester, const AlertsPage(), conn: conn, size: desktop);
      expect(find.text('session:s1'), findsOneWidget);
      expect(find.text('THROTTLE'), findsOneWidget);
      expect(find.textContaining('400% above baseline'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Resume')).onPressed, isNull);
    });
  });

  group('Connect', () {
    testWidgets('pasted forge:// string fills the token and connects; LAN http is warned about', (tester) async {
      final conn = EngineConnection();
      final stub = _wrap(conn);
      await pumpWithSize(tester, const ConnectPage(), conn: stub, size: phone);
      await tester.enterText(find.widgetWithText(TextField, 'Engine address or forge:// pairing string'), 'forge://192.168.1.20:8765?token=abc123&name=Studio');
      await tester.pump();
      expect(find.textContaining('unencrypted HTTP'), findsOneWidget);
      expect(find.textContaining('with the token from the pairing string'), findsOneWidget);
      await tester.ensureVisible(find.text('Connect'));
      await tester.tap(find.text('Connect'));
      await tester.pump();
      final c = stub.configured.single;
      expect(c.$1.host, '192.168.1.20');
      expect(c.$1.name, 'Studio');
      expect(c.$2, 'abc123');
    });

    testWidgets('the token field is masked and invalid input is rejected', (tester) async {
      await pumpWithSize(tester, const ConnectPage(), conn: _wrap(EngineConnection()), size: phone);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Bearer token')).obscureText, isTrue);
      await tester.enterText(find.widgetWithText(TextField, 'Engine address or forge:// pairing string'), 'ftp://nope');
      await tester.ensureVisible(find.text('Connect'));
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(find.textContaining('Enter an address'), findsOneWidget);
    });
  });
}

/// Wraps a bare [EngineConnection] state into a [StubConnection] with no data.
StubConnection _wrap(EngineConnection from) {
  final s = StubConnection(stateJson: const {}, actions: false);
  s.state = from.state;
  s.status = from.status;
  s.error = from.error;
  s.endpoint = from.endpoint;
  s.lastStateAt = from.lastStateAt;
  s.debugApply();
  return s;
}
