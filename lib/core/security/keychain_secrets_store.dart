import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secrets_store.dart';

/// Production secret store backed by the macOS Keychain (and the equivalent
/// platform secure storage on iOS/Android) via the `flutter_secure_storage`
/// platform channel. Every ref is stored as a separate Keychain item keyed
/// `<serviceName>.<ref>`, with the value in the item's password attribute so
/// keys never touch plain files on disk.
///
/// This lives in its own file — separate from the pure-Dart
/// [SecretsStore] interface — because `flutter_secure_storage` is a Flutter
/// plugin, while `bin/forge.dart` (which also needs a [SecretsStore]) runs
/// on the plain Dart VM. Tests use [InMemorySecretsStore] instead, since
/// Keychain Services are unavailable in a unit-test VM.
///
/// No extra entitlements are needed for the app's own default Keychain; add
/// the Keychain Sharing capability only if you later want Forge's items
/// shared across a team's app group.
class KeychainSecretsStore implements SecretsStore {
  KeychainSecretsStore({required this.serviceName, FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final String serviceName;
  final FlutterSecureStorage _storage;

  String _key(String ref) => '$serviceName.$ref';

  @override
  Future<void> write(String ref, String value) => _storage.write(
        key: _key(ref),
        value: value,
      );

  @override
  Future<String?> read(String ref) async {
    try {
      return await _storage.read(key: _key(ref));
    } on ArgumentError {
      // flutter_secure_storage signals "item not found" as an ArgumentError
      // on some platforms; a missing ref is simply null.
      return null;
    }
  }

  @override
  Future<void> delete(String ref) => _storage.delete(key: _key(ref));

  @override
  Future<List<String>> listRefs() async {
    final all = await _storage.readAll();
    final prefix = '$serviceName.';
    return all.keys
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .toList(growable: false);
  }
}
