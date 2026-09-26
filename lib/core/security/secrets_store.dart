/// Secure secret storage abstraction. API keys must never be written to
/// project files, Git, or plain JSON on disk — every place in Forge that
/// needs a credential goes through this interface.
///
/// The macOS-Keychain production implementation lives in
/// `keychain_secrets_store.dart` (kept in a separate file because it imports
/// the `flutter_secure_storage` Flutter plugin, while this file must stay
/// pure Dart — the `bin/forge.dart` CLI runs on the plain Dart VM).
abstract class SecretsStore {
  Future<void> write(String ref, String value);
  Future<String?> read(String ref);
  Future<void> delete(String ref);
  Future<List<String>> listRefs();
}


/// In-memory implementation used by tests and by any environment lacking a
/// platform secure-storage backend.
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

