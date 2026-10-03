import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../security/keychain_secrets_store.dart';
import '../security/secrets_store.dart';
import 'alert_notifier.dart';
import 'engine_connection.dart';
import 'engine_credentials.dart';

/// Secure storage for the engine bearer token. Real platform secure storage
/// (Keychain / Keystore) on macOS, iOS and Android; in-memory in tests.
final engineSecretsProvider = Provider<SecretsStore>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return InMemorySecretsStore();
  if (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) {
    return KeychainSecretsStore(serviceName: 'app.forge.engine');
  }
  return InMemorySecretsStore();
});

final engineCredentialsProvider =
    Provider<EngineCredentialStore>((ref) => EngineCredentialStore(secrets: ref.watch(engineSecretsProvider)));

/// The one link to the Forge engine, shared by every screen.
final engineConnectionProvider = ChangeNotifierProvider<EngineConnection>((ref) {
  final c = EngineConnection(credentials: ref.watch(engineCredentialsProvider));
  ref.onDispose(c.dispose);
  return c;
});

final alertNotifierProvider = Provider<AlertNotifier>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST') || !LocalAlertNotifier.supported) return const NoopAlertNotifier();
  return LocalAlertNotifier();
});

/// Whether critical engine alerts raise OS notifications (default on).
final criticalNotificationsEnabledProvider = StateProvider<bool>((ref) => true);
