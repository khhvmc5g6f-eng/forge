import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge/app/forge_providers.dart';
import 'package:forge/core/cloud/cloud_models.dart';
import 'package:forge/core/cloud/cloud_wallet_service.dart';
import 'package:forge/core/cloud/forge_cloud_client.dart';
import 'package:forge/core/cloud/money.dart';
import 'package:forge/ui/panels/wallet_panel.dart';

class _FakeWalletService implements CloudWalletService {
  _FakeWalletService({this.snapshot, this.error});

  final WalletSnapshot? snapshot;
  final Object? error;
  int refreshes = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<WalletSnapshot> refresh() async {
    refreshes++;
    if (error != null) throw error!;
    return snapshot!;
  }
}

Future<void> _pump(WidgetTester tester, CloudWalletService service) async {
  tester.view.physicalSize = const Size(900, 1500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [cloudWalletServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(home: Scaffold(body: WalletPanel())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the empty state when Forge Cloud is not configured',
      (tester) async {
    await _pump(tester, const NotConfiguredCloudWalletService());

    expect(find.text('Forge Cloud not configured'), findsOneWidget);
    expect(find.text('Balance'), findsNothing);
  });

  testWidgets('shows balance, month-to-date spend and usage rows', (tester) async {
    final snapshot = WalletSnapshot(
      balance: Money(BigInt.from(42500000000), 'GBP'),
      monthToDateSpend: Money(BigInt.from(7500000000), 'GBP'),
      recentUsage: [
        UsageRow(
          id: 'u1',
          model: 'dep-a',
          inputTokens: 120,
          outputTokens: 30,
          cost: Money(BigInt.from(1250000000), 'GBP'),
          at: DateTime.utc(2026, 10, 5, 9, 30),
        ),
      ],
      fetchedAt: DateTime.utc(2026, 10, 11),
    );
    final service = _FakeWalletService(snapshot: snapshot);

    await _pump(tester, service);

    expect(find.text('Balance'), findsOneWidget);
    expect(find.text('£42.50'), findsOneWidget);
    expect(find.text('Month-to-date spend'), findsOneWidget);
    expect(find.text('£7.50'), findsOneWidget);
    expect(find.text('dep-a'), findsOneWidget);
    expect(find.text('£1.25'), findsOneWidget);
    expect(find.textContaining('120 in / 30 out'), findsOneWidget);
    expect(service.refreshes, 1);
  });

  testWidgets('shows a sign-in message when the token is missing', (tester) async {
    final service = _FakeWalletService(
      error: ForgeCloudException('Not signed in to Forge Cloud.', statusCode: 401),
    );

    await _pump(tester, service);

    expect(find.text('Not signed in to Forge Cloud.'), findsOneWidget);
  });

  testWidgets('refresh button reloads the snapshot', (tester) async {
    final service = _FakeWalletService(
      snapshot: WalletSnapshot(
        balance: Money.zero('GBP'),
        monthToDateSpend: Money.zero('GBP'),
        recentUsage: const [],
        fetchedAt: DateTime.utc(2026, 10, 11),
      ),
    );

    await _pump(tester, service);
    expect(find.text('No usage recorded yet.'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh wallet'));
    await tester.pumpAndSettle();

    expect(service.refreshes, 2);
  });
}
