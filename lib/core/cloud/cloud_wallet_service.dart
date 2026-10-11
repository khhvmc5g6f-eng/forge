import 'package:meta/meta.dart';

import 'cloud_models.dart';
import 'forge_cloud_client.dart';
import 'money.dart';

/// Everything the Wallet and usage panel shows, fetched in one refresh.
@immutable
class WalletSnapshot {
  const WalletSnapshot({
    required this.balance,
    required this.monthToDateSpend,
    required this.recentUsage,
    required this.fetchedAt,
  });

  final Money balance;
  final Money monthToDateSpend;
  final List<UsageRow> recentUsage;
  final DateTime fetchedAt;
}

/// What the UI reads. When Forge Cloud is not configured, [isConfigured] is
/// false and [refresh] throws [ForgeCloudNotConfiguredException]; local
/// models, BYOK and every other provider are unaffected.
abstract class CloudWalletService {
  bool get isConfigured;

  /// Fetches balance and usage. Throws [ForgeCloudException] on transport,
  /// auth or contract errors.
  Future<WalletSnapshot> refresh();
}

/// Used when no Forge Cloud URL is set.
class NotConfiguredCloudWalletService implements CloudWalletService {
  const NotConfiguredCloudWalletService();

  @override
  bool get isConfigured => false;

  @override
  Future<WalletSnapshot> refresh() =>
      Future<WalletSnapshot>.error(const ForgeCloudNotConfiguredException());
}

/// Wallet service backed by [ForgeCloudClient].
class ForgeCloudWalletService implements CloudWalletService {
  ForgeCloudWalletService(
    this._client, {
    this.recentLimit = 10,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ForgeCloudClient _client;
  final int recentLimit;
  final DateTime Function() _clock;

  @override
  bool get isConfigured => true;

  @override
  Future<WalletSnapshot> refresh() async {
    final wallet = await _client.getWalletBalance();
    final usage = await _client.getUsageSummary();
    final rows = [...usage.recent]..sort((a, b) => b.at.compareTo(a.at));
    return WalletSnapshot(
      balance: wallet.balance,
      monthToDateSpend: usage.monthToDateSpend,
      recentUsage: rows.take(recentLimit).toList(growable: false),
      fetchedAt: _clock(),
    );
  }
}
