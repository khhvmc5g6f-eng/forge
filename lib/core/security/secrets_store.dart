/// Secure secret storage abstraction. API keys must never be written to
/// project files, Git, or plain JSON on disk — every place in Forge that
/// needs a credential goes through this interface.
abstract class SecretsStore {
  Future<void> write(String ref, String value);
  Future<String?> read(String ref);
  Future<void> delete(String ref);
  Future<List<String>> listRefs();
}

/// In-memory implementation used by tests and by any environment lacking a
/// platform secure-storage backend. Never used for a real user's API keys
/// outside of tests: [KeychainSecretsStore] is the production implementation
/// on macOS.
class InMemorySecretsStore implements SecretsStore {
  final Map<String, String> _values = {};

  @override
  Future<void> write(String ref, String value) async {
    _values[ref] = value;
  }

  @override
  Future<String?> read(String ref) async => _values[ref];

  @override
  Future<void> delete(String ref) async {
    _values.remove(ref);
  }

  @override
  Future<List<String>> listRefs() async => _values.keys.toList(growable: false);
}

/// Production secret store backed by the macOS Keychain via the
/// `flutter_secure_storage` platform channel. This class only compiles and
/// runs correctly on a real macOS host with the Flutter macOS embedder
/// (Keychain Services is unavailable in this development container) — it is
/// wired here so the rest of the app depends only on [SecretsStore] and
/// picks up real Keychain-backed storage the moment it runs on macOS.
///
/// NOTE: requires adding `flutter_secure_storage` to pubspec.yaml and
/// enabling the Keychain Sharing capability + an appropriate
/// `keychain-access-group` entitlement in macos/Runner/*.entitlements before
/// shipping. Left as a documented integration point rather than a fake
/// implementation: see PROVIDERS.md.
class KeychainSecretsStore implements SecretsStore {
  KeychainSecretsStore({required this.serviceName});

  final String serviceName;

  @override
  Future<void> write(String ref, String value) {
    throw UnimplementedError(
      'KeychainSecretsStore requires the flutter_secure_storage macOS '
      'platform channel and a signed app running on macOS. See '
      'PROVIDERS.md#secrets for the integration steps.',
    );
  }

  @override
  Future<String?> read(String ref) {
    throw UnimplementedError(
      'KeychainSecretsStore requires the flutter_secure_storage macOS '
      'platform channel and a signed app running on macOS. See '
      'PROVIDERS.md#secrets for the integration steps.',
    );
  }

  @override
  Future<void> delete(String ref) {
    throw UnimplementedError(
      'KeychainSecretsStore requires the flutter_secure_storage macOS '
      'platform channel and a signed app running on macOS. See '
      'PROVIDERS.md#secrets for the integration steps.',
    );
  }

  @override
  Future<List<String>> listRefs() {
    throw UnimplementedError(
      'KeychainSecretsStore requires the flutter_secure_storage macOS '
      'platform channel and a signed app running on macOS. See '
      'PROVIDERS.md#secrets for the integration steps.',
    );
  }
}
