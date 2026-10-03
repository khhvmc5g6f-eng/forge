import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/app.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';

import 'harness.dart';

void main() {
  testWidgets('phone app: engine chat tab and Control Centre tab, both clients of the engine', (tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final conn = StubConnection();
    await tester.pumpWidget(ProviderScope(
      overrides: [engineConnectionProvider.overrideWith((ref) => conn)],
      child: const MyApp(forceMobile: true, autoRestoreEngine: false),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Connect to Forge'), findsOneWidget, reason: 'chat tab first');
    await tester.tap(find.text('Control Centre'));
    await tester.pumpAndSettle();
    expect(find.text('Can Forge serve requests right now?'), findsOneWidget);
    expect(find.text('DEGRADED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet app (portrait iPad width) uses a rail', (tester) async {
    tester.view.physicalSize = tablet;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [engineConnectionProvider.overrideWith((ref) => StubConnection())],
      child: const MyApp(forceMobile: true, autoRestoreEngine: false),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
