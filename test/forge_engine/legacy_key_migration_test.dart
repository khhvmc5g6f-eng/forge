import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';
import 'package:forge/core/security/secrets_store.dart';

import 'engine_client_test.dart' show until;
import 'fake_engine.dart';

/// A store that refuses to overwrite or delete (a locked Keychain).
class _StubbornStore extends InMemorySecretsStore {
  bool locked = false;
  @override
  Future<void> write(String ref, String value) async {
    if (locked) throw StateError('locked');
    await super.write(ref, value);
  }

  @override
  Future<void> delete(String ref) async {
    if (!locked) await super.delete(ref);
  }
}

EngineConnection _conn() => EngineConnection(
      pollInterval: const Duration(milliseconds: 60),
      pollIntervalWithoutStream: const Duration(milliseconds: 40),
      minRefreshGap: const Duration(milliseconds: 10),
      backoff: (_) => const Duration(milliseconds: 40),
    );

void main() {
  late FakeEngine engine;
  EngineConnection? conn;
  setUp(() => engine = FakeEngine(supportsActions: true, managementToken: 'tk'));
  tearDown(() async {
    conn?.dispose();
    conn = null;
    await engine.stop();
  });

  Future<EngineConnection> connect({String? token = 'tk'}) async {
    await engine.start();
    final c = conn = _conn();
    await c.configure(EngineEndpoint(host: '127.0.0.1', port: engine.port), token: token, persist: false);
    await until(() => c.isConnected && c.capabilitiesKnown);
    return c;
  }

  group('scan', () {
    test('finds only keys that exist, exposes only the last four characters, ignores blanks', () async {
      final store = InMemorySecretsStore();
      await store.write('anthropic_api_key', 'sk-ant-secret-1234');
      await store.write('openai_api_key', '   ');
      await store.write('unrelated_ref', 'x');
      final found = await LegacyKeyMigration(store).scan();
      expect(found.map((k) => k.ref), ['anthropic_api_key']);
      expect(found.single.tail, '1234');
      expect(found.single.toString(), isNot(contains('secret')));
    });

    test('covers the three refs the old Settings panel wrote', () async {
      final store = InMemorySecretsStore();
      for (final r in ['nvidia_nim_api_key', 'anthropic_api_key', 'openai_api_key']) {
        await store.write(r, 'value-$r');
      }
      expect((await LegacyKeyMigration(store).scan()).map((k) => k.ref), ['nvidia_nim_api_key', 'anthropic_api_key', 'openai_api_key']);
    });
  });

  test('guessProvider matches ids and names, and does not guess when nothing fits', () {
    const nim = LegacyKey(ref: 'nvidia_nim_api_key', label: 'NVIDIA NIM', providerHints: ['nvidia-nim', 'nvidia'], tail: '');
    expect(guessProvider(nim, const [EngineProvider(id: 'openai', name: 'OpenAI', kind: 'cloud', enabled: true), EngineProvider(id: 'nvidia_nim', name: 'NVIDIA', kind: 'cloud', enabled: true)])?.id, 'nvidia_nim');
    expect(guessProvider(nim, const [EngineProvider(id: 'my-gateway', name: 'NVIDIA NIM (work)', kind: 'cloud', enabled: true)])?.id, 'my-gateway');
    expect(guessProvider(nim, const [EngineProvider(id: 'ollama', name: 'Ollama', kind: 'local', enabled: true)]), isNull);
  });

  group('migrate', () {
    Future<(InMemorySecretsStore, LegacyKey)> seeded(SecretsStore? custom) async {
      final store = (custom ?? InMemorySecretsStore()) as InMemorySecretsStore;
      await store.write('openai_api_key', 'sk-legacy-5678');
      return (store, (await LegacyKeyMigration(store).scan()).single);
    }

    test('engine stores it, a fresh state lists it, then the old copy is deleted', () async {
      final c = await connect();
      final (store, key) = await seeded(null);
      final out = await LegacyKeyMigration(store).migrate(key, connection: c, providerId: 'openai', name: 'migrated');
      expect(out.status, MigrationStatus.migrated, reason: out.message);
      expect(out.keyId, 'k3');
      expect(engine.actions.single['body'], {'providerId': 'openai', 'name': 'migrated', 'secret': 'sk-legacy-5678'});
      expect(c.state!.keys.any((k) => k.id == 'k3'), isTrue);
      expect(await store.read('openai_api_key'), isNull);
      expect(out.message, isNot(contains('sk-legacy-5678')));
      expect(await LegacyKeyMigration(store).scan(), isEmpty);
    });

    test('engine refuses: old key untouched', () async {
      final c = await connect();
      final (store, key) = await seeded(null);
      final out = await LegacyKeyMigration(store).migrate(key, connection: c, providerId: 'nope', name: 'x');
      expect(out.status, MigrationStatus.failed);
      expect(out.message, contains('Unknown provider'));
      expect(await store.read('openai_api_key'), 'sk-legacy-5678');
    });

    test('engine accepts but does not list the key: old key kept ("unconfirmed")', () async {
      engine.addKeyListsKey = false;
      final c = await connect();
      final (store, key) = await seeded(null);
      final out = await LegacyKeyMigration(store).migrate(key, connection: c, providerId: 'openai', name: 'x');
      expect(out.status, MigrationStatus.unconfirmed);
      expect(await store.read('openai_api_key'), 'sk-legacy-5678');
    });

    test('read-only engine: blocked, nothing sent, old key readable', () async {
      engine = FakeEngine(); // no management API
      final c = await connect(token: null);
      final (store, key) = await seeded(null);
      expect(LegacyKeyMigration.blockedReason(c), contains('cannot add keys remotely'));
      final out = await LegacyKeyMigration(store).migrate(key, connection: c, providerId: 'openai', name: 'x');
      expect(out.status, MigrationStatus.blocked);
      expect(engine.actions, isEmpty);
      expect(await store.read('openai_api_key'), 'sk-legacy-5678');
    });

    test('management API without a valid token: blocked with the token reason', () async {
      final c = await connect(token: 'wrong');
      expect(LegacyKeyMigration.blockedReason(c), contains('bearer token'));
      expect(engine.actions, isEmpty);
    });

    test('engine unreachable: blocked, old key readable', () async {
      final c = await connect();
      await engine.stop();
      await until(() => !c.isConnected);
      final (store, key) = await seeded(null);
      final out = await LegacyKeyMigration(store).migrate(key, connection: c, providerId: 'openai', name: 'x');
      expect(out.status, MigrationStatus.blocked);
      expect(await store.read('openai_api_key'), 'sk-legacy-5678');
    });

    test('a store that refuses to delete is reported, and the key is still flagged as legacy', () async {
      final c = await connect();
      final stubborn = _StubbornStore();
      final (store, key) = await seeded(stubborn);
      stubborn.locked = true;
      final out = await LegacyKeyMigration(store).migrate(key, connection: c, providerId: 'openai', name: 'x');
      expect(out.status, MigrationStatus.storedButNotDeleted);
      expect(out.message, contains('could not be deleted'));
      expect(await store.read('openai_api_key'), 'sk-legacy-5678', reason: 'still there, so it stays flagged and readable');
      expect(await LegacyKeyMigration(store).scan(), hasLength(1));
    });

    test('never sends a key over unencrypted HTTP to another machine', () async {
      final c = EngineConnection()
        ..debugApply(
          endpoint: const EngineEndpoint(host: '192.168.1.20', port: 8765),
          status: EngineLinkStatus.connected,
          state: EngineState.fromJson(FakeEngine.baseState()),
          capabilities: EngineCapabilities.managementApi,
        );
      addTearDown(c.dispose);
      expect(LegacyKeyMigration.blockedReason(c), contains('unencrypted'));
    });
  });

  test('removeLegacy overwrites and deletes the old copy', () async {
    final store = InMemorySecretsStore();
    await store.write('groq_api_key', 'gsk-1');
    final key = (await LegacyKeyMigration(store).scan()).single;
    final out = await LegacyKeyMigration(store).removeLegacy(key);
    expect(out.done, isTrue);
    expect(await store.read('groq_api_key'), isNull);
  });
}
