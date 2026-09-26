import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/control_plane/credential_vault.dart';
import 'package:forge/core/security/secrets_store.dart';

void main() {
  late InMemorySecretsStore store;
  late CredentialVault vault;

  setUp(() {
    store = InMemorySecretsStore();
    vault = CredentialVault(store);
  });

  test('addCredential stores under provider::slot and becomes the default active slot', () async {
    await vault.addCredential('nvidia', 'key1', 'secret-value-1');
    expect(await vault.activeSlot('nvidia'), 'key1');
    expect(await vault.resolve('nvidia'), 'secret-value-1');
  });

  test('multiple slots per provider are tracked independently', () async {
    await vault.addCredential('nvidia', 'key1', 'v1');
    await vault.addCredential('nvidia', 'key2', 'v2');
    final slots = await vault.slotsFor('nvidia');
    expect(slots, containsAll(['key1', 'key2']));
    expect(await vault.resolve('nvidia', slot: 'key2'), 'v2');
  });

  test('setActiveSlot explicitly switches which credential resolve() returns', () async {
    await vault.addCredential('nvidia', 'key1', 'v1');
    await vault.addCredential('nvidia', 'key2', 'v2');
    expect(await vault.resolve('nvidia'), 'v1'); // first added is default

    vault.setActiveSlot('nvidia', 'key2');
    expect(await vault.resolve('nvidia'), 'v2');
  });

  test('resolve() never leaks a value for a provider with no configured credential', () async {
    expect(await vault.resolve('unknown-provider'), isNull);
  });

  test('providersConfigured lists every provider with at least one credential', () async {
    await vault.addCredential('nvidia', 'key1', 'v1');
    await vault.addCredential('groq', 'key1', 'v2');
    expect(await vault.providersConfigured(), containsAll(['nvidia', 'groq']));
  });

  test('removeCredential clears the active slot if it was the one removed', () async {
    await vault.addCredential('nvidia', 'key1', 'v1');
    await vault.removeCredential('nvidia', 'key1');
    expect(await vault.slotsFor('nvidia'), isEmpty);
    expect(await vault.activeSlot('nvidia'), isNull);
  });

  test('activeReferenceFor returns an opaque store key, never the raw secret', () async {
    await vault.addCredential('nvidia', 'key1', 'super-secret-value');
    final ref = await vault.activeReferenceFor('nvidia');
    expect(ref, 'nvidia::key1');
    expect(ref, isNot(contains('super-secret-value')));
  });
}
