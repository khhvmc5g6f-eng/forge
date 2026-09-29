import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedConnection {
  const SavedConnection({required this.url, this.roomSecret});
  final String url;
  final String? roomSecret;
}

class AppPrefs {
  const AppPrefs({
    this.provider,
    this.model,
    this.autonomy,
    this.speakReplies = false,
  });
  final String? provider;
  final String? model;
  final String? autonomy;
  final bool speakReplies;
}

/// Persistence boundary. The room secret is a credential: it lives only in the
/// platform keystore (Keychain / Android Keystore), never in shared preferences.
abstract class SettingsStore {
  Future<SavedConnection?> loadConnection();
  Future<void> saveConnection(SavedConnection c);
  Future<void> clearConnection();
  Future<AppPrefs> loadPrefs();
  Future<void> savePrefs(AppPrefs p);
  Future<int> loadVoicePort();
  Future<void> saveVoicePort(int port);
}

class PlatformSettingsStore implements SettingsStore {
  PlatformSettingsStore({FlutterSecureStorage? secure})
    : _secure =
          secure ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );
  final FlutterSecureStorage _secure;

  static const _kUrl = 'hub_url';
  static const _kSecret = 'hub_room_secret';

  /// The hub address is not a secret, so it lives in ordinary preferences and
  /// survives even where the keystore is unavailable (e.g. unsigned simulator
  /// builds). Only the room secret goes to the platform keystore.
  @override
  Future<SavedConnection?> loadConnection() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_kUrl);
    if (url == null || url.isEmpty) return null;
    String? secret;
    try {
      secret = await _secure.read(key: _kSecret);
    } catch (_) {
      secret = null; // keystore unavailable: user re-enters the secret
    }
    return SavedConnection(url: url, roomSecret: secret);
  }

  @override
  Future<void> saveConnection(SavedConnection c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, c.url);
    // Throws when the keystore rejects the write; callers decide how to report it.
    if (c.roomSecret == null || c.roomSecret!.isEmpty) {
      await _secure.delete(key: _kSecret);
    } else {
      await _secure.write(key: _kSecret, value: c.roomSecret);
    }
  }

  @override
  Future<void> clearConnection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUrl);
    try {
      await _secure.delete(key: _kSecret);
    } catch (_) {}
  }

  @override
  Future<AppPrefs> loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    return AppPrefs(
      provider: p.getString('provider'),
      model: p.getString('model'),
      autonomy: p.getString('autonomy'),
      speakReplies: p.getBool('speak') ?? false,
    );
  }

  @override
  Future<void> savePrefs(AppPrefs a) async {
    final p = await SharedPreferences.getInstance();
    Future<void> put(String k, String? v) async =>
        v == null ? p.remove(k) : p.setString(k, v);
    await put('provider', a.provider);
    await put('model', a.model);
    await put('autonomy', a.autonomy);
    await p.setBool('speak', a.speakReplies);
  }

  @override
  Future<int> loadVoicePort() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('voice_port') ?? 8790;
  }

  @override
  Future<void> saveVoicePort(int port) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('voice_port', port);
  }
}

class MemorySettingsStore implements SettingsStore {
  int voicePort = 8790;
  SavedConnection? connection;
  AppPrefs prefs = const AppPrefs();
  @override
  Future<SavedConnection?> loadConnection() async => connection;
  @override
  Future<void> saveConnection(SavedConnection c) async => connection = c;
  @override
  Future<void> clearConnection() async => connection = null;
  @override
  Future<AppPrefs> loadPrefs() async => prefs;
  @override
  Future<void> savePrefs(AppPrefs p) async => prefs = p;
  @override
  Future<int> loadVoicePort() async => voicePort;
  @override
  Future<void> saveVoicePort(int port) async => voicePort = port;
}
