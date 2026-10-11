import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/cloud/cloud_wallet_service.dart';
import '../../core/cloud/forge_cloud_client.dart';

/// Wallet and usage: Forge Cloud balance, month-to-date spend and the last
/// ten usage rows. With no Forge Cloud URL configured it shows an empty
/// state only; nothing else in Forge depends on this panel.
class WalletPanel extends ConsumerWidget {
  const WalletPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(cloudWalletServiceProvider);
    if (!service.isConfigured) {
      return const Center(child: Text(forgeCloudNotConfiguredMessage));
    }
    final snapshot = ref.watch(walletSnapshotProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Refresh wallet',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(walletSnapshotProvider),
              ),
            ],
          ),
        ),
        Expanded(
          child: snapshot.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: Text(error is ForgeCloudException && error.isUnauthenticated
                  ? 'Not signed in to Forge Cloud.'
                  : 'Could not load wallet: $error'),
            ),
            data: (data) => _WalletBody(snapshot: data),
          ),
        ),
      ],
    );
  }
}

class _WalletBody extends StatelessWidget {
  const _WalletBody({required this.snapshot});

  final WalletSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final rows = snapshot.recentUsage;
    return ListView(
      children: [
        ListTile(
          title: const Text('Balance'),
          trailing: Text(snapshot.balance.format()),
        ),
        ListTile(
          title: const Text('Month-to-date spend'),
          trailing: Text(snapshot.monthToDateSpend.format()),
        ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Recent usage'),
        ),
        if (rows.isEmpty)
          const ListTile(title: Text('No usage recorded yet.'))
        else
          for (final row in rows)
            ListTile(
              dense: true,
              title: Text(row.model),
              subtitle: Text(
                '${row.inputTokens} in / ${row.outputTokens} out · '
                '${_date(row.at)}',
              ),
              trailing: Text(row.cost.format()),
            ),
      ],
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _date(DateTime at) {
    final t = at.toLocal();
    return '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}';
  }
}
