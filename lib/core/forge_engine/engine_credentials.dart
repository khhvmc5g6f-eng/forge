import 'package:shared_preferences/shared_preferences.dart';

import '../security/secrets_store.dart';
import 'engine_endpoint.dart';

class SavedEngine {
  const SavedEngine(this.endpoint, this.token);
  final EngineEndpoint endpoint;
  final String? token;
}

/// Persists which engine to talk to. The address is ordinary preferences; the
/// bearer token lives only in the platform secure store (Keychain on
/// macOS/iOS, Keystore-backed storage on Android) via [SecretsStore].
class EngineCredentialStore {
  EngineCredentialStore({required this._secrets});

  static const _tokenRef = 'forge-engine.bearer-token';
  static const _kHost = 'forge.engine.host';
  static const _kPort = 'forge.engine.port';
  static const _kTls = 'forge.engine.tls';
  static const _kName = 'forge.engine.name';

  final SecretsStore _secrets;

  Future<SavedEngine?> load() async {
    final p = await SharedPreferences.getInstance();
    final host = p.getString(_kHost);
    if (host == null || host.isEmpty) return null;
    String? token;
    try {
      token = await _secrets.read(_tokenRef);
    } catch (_) {
      token = null;
    }
    return SavedEngine(
      EngineEndpoint(host: host, port: p.getInt(_kPort) ?? EngineEndpoint.defaultPort, tls: p.getBool(_kTls) ?? false, name: p.getString(_kName)),
      token,
    );
  }

  /// Returns false when the secure store refused the token (e.g. an unsigned
  /// debug build without Keychain access). The caller keeps the token in memory
  /// for this session and tells the user it was not persisted.
  Future<bool> save(EngineEndpoint endpoint, String? token) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kHost, endpoint.host);
    await p.setInt(_kPort, endpoint.port);
    await p.setBool(_kTls, endpoint.tls);
    if (endpoint.name != null) {
      await p.setString(_kName, endpoint.name!);
    } else {
      await p.remove(_kName);
    }
    try {
      if (token == null || token.isEmpty) {
        await _secrets.delete(_tokenRef);
      } else {
        await _secrets.write(_tokenRef, token);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kHost, _kPort, _kTls, _kName]) {
      await p.remove(k);
    }
    try {
      await _secrets.delete(_tokenRef);
    } catch (_) {}
  }
}
