import '../security/secrets_store.dart';
import 'engine_client.dart';
import 'engine_connection.dart';
import 'engine_models.dart';

/// A provider API key that an earlier build of this app saved in the app's own
/// secure storage (service `app.forge.secrets`), outside the engine vault.
///
/// Policy (docs: CREDENTIAL_POLICY.md, SETTINGS_CONSOLIDATION.md): provider
/// credentials live only in the engine vault. These old copies stay readable
/// (the legacy on-device model providers still read them) but are flagged
/// "legacy — move to engine", receive no new writes, and are deleted only
/// after the engine has confirmed it stored the key.
class LegacyKey {
  const LegacyKey({required this.ref, required this.label, required this.providerHints, required this.tail});

  /// The secure-storage ref (e.g. `anthropic_api_key`).
  final String ref;
  final String label;

  /// Engine provider ids this key most likely belongs to, best first.
  final List<String> providerHints;

  /// Last four characters, for the confirmation dialog only. Never the whole key.
  final String tail;
}

class _Known {
  const _Known(this.ref, this.label, this.hints);
  final String ref, label;
  final List<String> hints;
}

/// Every ref the old app (or its Dart model providers) used for provider keys.
/// The Settings panel wrote the first three; the rest are read by the Dart
/// providers and are covered so no copy is left behind.
const _known = <_Known>[
  _Known('nvidia_nim_api_key', 'NVIDIA NIM', ['nvidia-nim', 'nvidia', 'nim']),
  _Known('anthropic_api_key', 'Anthropic', ['anthropic', 'claude']),
  _Known('openai_api_key', 'OpenAI', ['openai']),
  _Known('groq_api_key', 'Groq', ['groq']),
  _Known('cerebras_api_key', 'Cerebras', ['cerebras']),
  _Known('openrouter_api_key', 'OpenRouter', ['openrouter']),
  _Known('zai_api_key', 'Z.AI', ['zai', 'z-ai', 'zhipu']),
  _Known('google_api_key', 'Google', ['google', 'gemini']),
];

/// Best engine provider for [key] among [providers], or null when none matches
/// (the user then picks one; the migration never guesses silently).
EngineProvider? guessProvider(LegacyKey key, List<EngineProvider> providers) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  for (final hint in key.providerHints) {
    for (final p in providers) {
      if (norm(p.id) == norm(hint)) return p;
    }
  }
  for (final hint in key.providerHints) {
    for (final p in providers) {
      if (norm(p.name).contains(norm(hint)) || norm(p.id).contains(norm(hint))) return p;
    }
  }
  return null;
}

enum MigrationStatus {
  /// Engine stored it, a fresh state snapshot lists it, old copy removed.
  migrated,

  /// Nothing was sent: not connected, engine lacks `key.add`, unsafe transport, or the key was already gone.
  blocked,

  /// The engine refused or the call failed. The old key is untouched.
  failed,

  /// The engine accepted it but a state refresh does not list the key, so the
  /// old copy was kept.
  unconfirmed,

  /// The engine has the key, but the old copy could not be removed. It is still flagged legacy.
  storedButNotDeleted,
}

class MigrationOutcome {
  const MigrationOutcome(this.status, this.message, {this.keyId});
  final MigrationStatus status;
  final String message;
  final String? keyId;
  bool get done => status == MigrationStatus.migrated;
}

/// Finds legacy keys and moves them into the engine vault.
class LegacyKeyMigration {
  LegacyKeyMigration(this._store);
  final SecretsStore _store;

  /// Legacy keys currently present. Reads secure storage; returns no secret.
  Future<List<LegacyKey>> scan() async {
    final found = <LegacyKey>[];
    for (final k in _known) {
      String? v;
      try {
        v = await _store.read(k.ref);
      } catch (_) {
        v = null;
      }
      if (v == null || v.trim().isEmpty) continue;
      final t = v.trim();
      found.add(LegacyKey(ref: k.ref, label: k.label, providerHints: k.hints, tail: t.length <= 4 ? '' : t.substring(t.length - 4)));
    }
    return found;
  }

  /// Why [migrate] cannot run right now, or null.
  static String? blockedReason(EngineConnection c) {
    if (!c.isConnected) return 'Not connected to the engine. The old key stays where it is.';
    if (!c.capabilitiesKnown) return 'Checking what this engine allows…';
    final caps = c.capabilities;
    if (caps.authRejected) return 'The engine\'s management API needs a valid bearer token (Settings > Engine connection).';
    if (!caps.supports('key.add')) return 'This engine cannot add keys remotely (no management API). The old key stays where it is; add it on the engine.';
    final e = c.endpoint;
    if (e != null && !e.safeForSecrets) return 'The link to the engine is unencrypted HTTP to another machine; a key is never sent over it.';
    final s = c.state;
    if (s == null || s.providers.isEmpty) return 'The engine reports no providers to attach the key to.';
    return null;
  }

  /// Sends the key to the engine, waits for the engine's own confirmation (the
  /// created key id, listed in a fresh state snapshot), and only then
  /// overwrites and deletes the old copy. Call only after the user confirmed.
  Future<MigrationOutcome> migrate(LegacyKey key, {required EngineConnection connection, required String providerId, required String name}) async {
    final why = blockedReason(connection);
    if (why != null) return MigrationOutcome(MigrationStatus.blocked, why);
    String? secret;
    try {
      secret = (await _store.read(key.ref))?.trim();
    } catch (_) {
      secret = null;
    }
    if (secret == null || secret.isEmpty) return const MigrationOutcome(MigrationStatus.blocked, 'The old key is no longer in secure storage.');

    EngineActionResult r;
    try {
      r = await connection.run((c) => c.addKey(providerId: providerId, name: name, secret: secret!));
    } on EngineException catch (e) {
      return MigrationOutcome(MigrationStatus.failed, 'The engine did not store the key: ${e.message}. The old key is untouched.');
    } finally {
      secret = null;
    }
    final id = r.data['id'];
    if (!r.ok || id is! String || id.isEmpty) {
      return const MigrationOutcome(MigrationStatus.unconfirmed, 'The engine answered without confirming a stored key. The old key was kept.');
    }
    final listed = connection.state?.keys.any((k) => k.id == id && k.providerId == providerId) ?? false;
    if (!listed) {
      return MigrationOutcome(MigrationStatus.unconfirmed, 'The engine accepted the key but a fresh state does not list it yet. The old key was kept; refresh and try again.', keyId: id);
    }
    return _removeOld(key, id);
  }

  /// Deletes the old copy (user-confirmed "remove legacy copy"). Overwrites
  /// first so a store that keeps history does not retain the secret, then
  /// verifies it is gone.
  Future<MigrationOutcome> removeLegacy(LegacyKey key) async {
    final out = await _removeOld(key, null);
    return out.status == MigrationStatus.migrated ? const MigrationOutcome(MigrationStatus.migrated, 'Legacy copy deleted from this device.') : out;
  }

  Future<MigrationOutcome> _removeOld(LegacyKey key, String? keyId) async {
    try {
      await _store.write(key.ref, '');
    } catch (_) {
      // Overwrite is best effort; the delete below is what counts.
    }
    try {
      await _store.delete(key.ref);
      final left = await _store.read(key.ref);
      if (left == null || left.isEmpty) {
        return MigrationOutcome(MigrationStatus.migrated, '${key.label} key stored in the engine vault; the old copy was deleted from this device.', keyId: keyId);
      }
    } catch (_) {}
    return MigrationOutcome(MigrationStatus.storedButNotDeleted,
        'The engine has the ${key.label} key, but the old copy could not be deleted from secure storage. It stays flagged as legacy; remove it from Keychain Access (service app.forge.secrets).',
        keyId: keyId);
  }
}
