import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app.dart';
import 'package:forge/app/forge_providers.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';
import 'package:forge/core/security/secrets_store.dart';
import 'package:forge/ui/engine/engine_console.dart';
import 'package:forge/ui/panels/settings_panel.dart';
import 'package:forge/ui/settings/settings_nav.dart';
import 'package:forge/ui/settings/settings_screen.dart';
import 'package:forge/ui/shell/forge_shell.dart';
import 'package:forge/ui/shell/mobile_home.dart';
import 'package:forge/ui/shell/sidebar_section.dart';

import '../../forge_engine/fake_engine.dart';
import '../engine/harness.dart';

/// Pretends the engine confirmed the key: records the call and adds the key to state.
class _ConfirmingConnection extends StubConnection {
  _ConfirmingConnection();
  final stored = <String>[];

  @override
  Future<EngineActionResult> run(Future<EngineActionResult> Function(EngineClient c) action) async {
    final r = await action(_Capturing(stored));
    final j = FakeEngine.baseState();
    (j['keys'] as List<dynamic>).add({'id': 'k9', 'name': 'migrated', 'providerId': 'openai', 'masked': 'sk-…5678', 'enabled': true});
    debugApply(state: EngineState.fromJson(j));
    return r;
  }
}

class _Capturing extends EngineClient {
  _Capturing(this.log) : super(endpoint: const EngineEndpoint(host: '127.0.0.1', port: 1));
  final List<String> log;
  @override
  Future<EngineActionResult> addKey({required String providerId, required String name, required String secret, int? priority}) async {
    log.add('$providerId|$name|$secret');
    return const EngineActionResult(ok: true, message: 'stored', data: {'id': 'k9'});
  }
}

Future<void> pumpSettings(WidgetTester tester, Widget child, {required StubConnection conn, InMemorySecretsStore? secrets, Size size = const Size(1000, 900)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [engineConnectionProvider.overrideWith((ref) => conn), if (secrets != null) secretsStoreProvider.overrideWithValue(secrets)],
    child: MaterialApp(theme: ThemeData(useMaterial3: true), home: Scaffold(body: child)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('Settings & Connections screen', () {
    testWidgets('has only real sections; desktop adds the on-device agent', (tester) async {
      await pumpSettings(tester, const SettingsScreen(), conn: StubConnection(), size: desktop);
      expect(find.text('Settings & Connections'), findsOneWidget);
      for (final l in ['Engine connection', 'Provider credentials', 'Notifications']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      expect(find.text('On-device agent'), findsNothing, reason: 'not on the phone/tablet shell');
      await pumpSettings(tester, const SettingsPanel(), conn: StubConnection(), size: desktop);
      expect(find.text('On-device agent'), findsWidgets);
    });

    testWidgets('provider credentials: engine vault only, no free-standing key field, no legacy panel when none exist', (tester) async {
      await pumpSettings(tester, const SettingsPanel(), conn: StubConnection(), size: desktop);
      await tester.tap(find.text('Provider credentials').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('entered only here, into the engine vault'), findsOneWidget);
      expect(find.text('OpenAI'), findsOneWidget, reason: 'the engine vault listing');
      expect(find.byType(TextField), findsNothing, reason: 'keys are typed only in the Add key dialog');
      expect(find.text('NVIDIA NIM'), findsNothing);
      expect(find.textContaining('Legacy keys'), findsNothing);
    });

    testWidgets('the old three key inputs are gone from the on-device section', (tester) async {
      await pumpSettings(tester, const SettingsPanel(), conn: StubConnection(), size: desktop);
      await tester.tap(find.text('On-device agent').first);
      await tester.pumpAndSettle();
      expect(find.text('Operating mode'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('Anthropic'), findsNothing);
      expect(find.byIcon(Icons.save_outlined), findsNothing);
    });

    testWidgets('phone: chip bar switches sections without overflow', (tester) async {
      await pumpSettings(tester, const SettingsScreen(), conn: StubConnection(), size: phone);
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Notifications'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('Notify me about critical alerts'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('notification preference is edited here', (tester) async {
      await pumpSettings(tester, const SettingsScreen(), conn: StubConnection(), size: desktop);
      await tester.tap(find.text('Notifications').first);
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
      expect(container.read(criticalNotificationsEnabledProvider), isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(container.read(criticalNotificationsEnabledProvider), isFalse);
    });
  });

  group('Legacy keys', () {
    Future<InMemorySecretsStore> seed() async {
      final s = InMemorySecretsStore();
      await s.write('openai_api_key', 'sk-legacy-5678');
      await s.write('anthropic_api_key', 'sk-ant-legacy-4321');
      return s;
    }

    testWidgets('flagged "legacy — move to engine", masked, with no way to write a new one', (tester) async {
      final secrets = await seed();
      await pumpSettings(tester, const SettingsPanel(), conn: StubConnection(), secrets: secrets, size: desktop);
      await tester.tap(find.text('Provider credentials').first);
      await tester.pumpAndSettle();
      expect(find.text('Legacy keys on this device'), findsOneWidget);
      expect(find.text('legacy — move to engine'), findsNWidgets(2));
      expect(find.text('••••5678'), findsOneWidget);
      expect(find.textContaining('sk-legacy'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('engine without the action API: move disabled with the reason, old keys stay readable', (tester) async {
      final secrets = await seed();
      await pumpSettings(tester, const SettingsPanel(), conn: StubConnection(actions: false), secrets: secrets, size: desktop);
      await tester.tap(find.text('Provider credentials').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('cannot add keys remotely'), findsOneWidget);
      for (final b in tester.widgetList<FilledButton>(find.widgetWithText(FilledButton, 'Move to engine vault'))) {
        expect(b.onPressed, isNull);
      }
      expect(await secrets.read('openai_api_key'), 'sk-legacy-5678');
    });

    testWidgets('move: user confirms, engine confirms, old copy is deleted', (tester) async {
      final secrets = await seed();
      final conn = _ConfirmingConnection();
      await pumpSettings(tester, const SettingsPanel(), conn: conn, secrets: secrets, size: desktop);
      await tester.tap(find.text('Provider credentials').first);
      await tester.pumpAndSettle();
      // rows follow the catalog order: Anthropic, then OpenAI (the last one)
      await tester.tap(find.widgetWithText(FilledButton, 'Move to engine vault').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('sent once to the engine vault'), findsOneWidget);
      expect(conn.stored, isEmpty, reason: 'nothing is sent before the user confirms');
      await tester.tap(find.widgetWithText(FilledButton, 'Move key'));
      await tester.pumpAndSettle();
      expect(conn.stored, hasLength(1));
      expect(conn.stored.single, 'openai|migrated|sk-legacy-5678');
      expect(await secrets.read('openai_api_key'), isNull, reason: 'old copy deleted after the engine confirmed');
      expect(await secrets.read('anthropic_api_key'), 'sk-ant-legacy-4321');
      expect(find.text('legacy — move to engine'), findsOneWidget, reason: 'the other legacy key remains');
    });

    testWidgets('cancelling the move sends nothing and keeps the key', (tester) async {
      final secrets = await seed();
      final conn = _ConfirmingConnection();
      await pumpSettings(tester, const SettingsPanel(), conn: conn, secrets: secrets, size: desktop);
      await tester.tap(find.text('Provider credentials').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Move to engine vault').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(conn.stored, isEmpty);
      expect(await secrets.read('openai_api_key'), 'sk-legacy-5678');
      expect(await secrets.read('anthropic_api_key'), 'sk-ant-legacy-4321');
    });

    testWidgets('delete legacy copy asks first', (tester) async {
      final secrets = await seed();
      await pumpSettings(tester, const SettingsPanel(), conn: StubConnection(actions: false), secrets: secrets, size: desktop);
      await tester.tap(find.text('Provider credentials').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete legacy copy').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await secrets.listRefs(), hasLength(2));
      await tester.tap(find.widgetWithText(TextButton, 'Delete legacy copy').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(await secrets.listRefs(), ['openai_api_key'], reason: 'the first row (Anthropic) was deleted, the other stays');
      expect(find.text('legacy — move to engine'), findsOneWidget);
    });
  });

  group('Deep links from the Control Centre', () {
    testWidgets('dashboard "manage providers and keys" opens Settings > Provider credentials (desktop shell)', (tester) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [engineConnectionProvider.overrideWith((ref) => StubConnection())],
        child: MaterialApp(home: const ForgeShell()),
      ));
      final container = ProviderScope.containerOf(tester.element(find.byType(ForgeShell)));
      container.read(selectedSectionProvider.notifier).state = SidebarSection.controlCentre;
      await tester.pumpAndSettle();
      expect(find.text('Manage providers and keys in Settings'), findsOneWidget);
      await tester.tap(find.text('Manage providers and keys in Settings'));
      await tester.pumpAndSettle();
      expect(container.read(selectedSectionProvider), SidebarSection.settings);
      expect(container.read(settingsSectionProvider), SettingsSection.credentials);
      expect(find.textContaining('entered only here, into the engine vault'), findsOneWidget);
    });

    testWidgets('phone shell: Settings tab, and the console deep link lands on it', (tester) async {
      tester.view.physicalSize = phone;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [engineConnectionProvider.overrideWith((ref) => StubConnection())],
        child: const MyApp(forceMobile: true, autoRestoreEngine: false),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Control Centre'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Manage providers and keys in Settings'));
      await tester.tap(find.text('Manage providers and keys in Settings'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(MobileHome)));
      expect(container.read(mobileTabProvider), MobileTab.settings);
      expect(find.text('Settings & Connections'), findsOneWidget);
      expect(find.textContaining('entered only here, into the engine vault'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Control Centre has no vault or connection page and never shows key entry', (tester) async {
      tester.view.physicalSize = desktop;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [engineConnectionProvider.overrideWith((ref) => StubConnection())],
        child: const MaterialApp(home: Scaffold(body: EngineConsole())),
      ));
      await tester.pumpAndSettle();
      expect(EnginePage.values.map((p) => p.name), isNot(containsAll(['vault', 'connection'])));
      expect(find.text('Add key'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });
  });

  test('guard: no lib file writes a provider key into the app secret store', () {
    final offenders = <String>[];
    // lib/core/control_plane/ is the deprecated Dart vault: unused by any UI, slated for removal (CONTROL_PLANE.md).
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.contains('core/control_plane/'))) {
      final src = f.readAsStringSync();
      if (RegExp(r'secretsStoreProvider\)\.write|secretsStore\.write|_secretsStore\.write').hasMatch(src)) offenders.add(f.path);
      if (src.contains('_ApiKeyField')) offenders.add(f.path);
    }
    // The only writers of app secrets are: the engine bearer token (engine_credentials) and the legacy migration's overwrite-before-delete.
    expect(offenders, isEmpty);
  });
}
