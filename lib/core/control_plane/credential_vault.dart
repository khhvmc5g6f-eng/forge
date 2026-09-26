import '../security/secrets_store.dart';

/// One named credential slot for a provider, e.g. `nvidia`/`key1`. Multiple
/// slots per provider exist for **legitimate deployment redundancy** —
/// separate projects, organisations, environments, or billing accounts —
/// never to route around a single account's rate limit. See
/// [CredentialVault]'s class doc for the enforcement of that boundary.
class CredentialSlot {
  const CredentialSlot({required this.provider, required this.name});
  final String provider;
  final String name;

  String get storeKey => '$provider::$name';

  static CredentialSlot fromStoreKey(String key) {
    final parts = key.split('::');
    return CredentialSlot(provider: parts[0], name: parts.sublist(1).join('::'));
  }
}

/// Manages multiple named credentials per provider on top of [SecretsStore]
/// (the macOS Keychain in production). Every secret is stored under a
/// `<provider>::<slot>` key; nothing in this class, or anything that calls
/// it, ever holds a raw secret value longer than the single call that needs
/// it — [ModelProvider] adapters resolve a secret by reference at request
/// time (see `lib/core/models/providers/openai_compatible_provider.dart`)
/// and never log, cache, or forward it.
///
/// **Rotation policy**: [activeSlot] returns whichever slot the user (or a
/// deployment config) has explicitly designated the default for a provider
/// — set via [setActiveSlot]. This class deliberately does **not** implement
/// automatic rotation on failure/429: that would be using credential
/// redundancy to circumvent a provider's rate limit, which the spec
/// explicitly forbids ("Do NOT use credential rotation to circumvent
/// provider rate limits or terms"). A rate-limited credential's circuit
/// breaker (`lib/core/control_plane/circuit_breaker.dart`) still opens
/// normally; recovering from that means waiting out the provider's own
/// cooldown, or a human deliberately switching [setActiveSlot] to a genuinely
/// separate account they are authorised to use — never an automatic
/// same-cause-different-key retry loop.
class CredentialVault {
  CredentialVault(this._secretsStore);

  final SecretsStore _secretsStore;
  final Map<String, String> _activeSlotByProvider = {};

  Future<void> addCredential(String provider, String slot, String value) async {
    await _secretsStore.write(CredentialSlot(provider: provider, name: slot).storeKey, value);
    _activeSlotByProvider.putIfAbsent(provider, () => slot);
  }

  Future<void> removeCredential(String provider, String slot) async {
    await _secretsStore.delete(CredentialSlot(provider: provider, name: slot).storeKey);
    if (_activeSlotByProvider[provider] == slot) {
      _activeSlotByProvider.remove(provider);
    }
  }

  /// Slot names configured for [provider] — never the secret values.
  Future<List<String>> slotsFor(String provider) async {
    final all = await _secretsStore.listRefs();
    final prefix = '$provider::';
    return all
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .toList(growable: false);
  }

  Future<List<String>> providersConfigured() async {
    final all = await _secretsStore.listRefs();
    return all.map((k) => CredentialSlot.fromStoreKey(k).provider).toSet().toList();
  }

  /// The slot a provider adapter should use right now. Defaults to the
  /// first slot added if none has been explicitly designated.
  Future<String?> activeSlot(String provider) async {
    if (_activeSlotByProvider.containsKey(provider)) {
      return _activeSlotByProvider[provider];
    }
    final slots = await slotsFor(provider);
    return slots.isEmpty ? null : slots.first;
  }

  /// Explicitly switches which credential a provider uses — a deliberate
  /// human action (e.g. "use the org account for this project"), not an
  /// automatic failover response.
  void setActiveSlot(String provider, String slot) {
    _activeSlotByProvider[provider] = slot;
  }

  /// Resolves the actual secret value for [provider]'s active slot (or an
  /// explicit [slot]) — called only by a [ModelProvider] adapter at request
  /// time, never surfaced to UI, logs, or model context.
  Future<String?> resolve(String provider, {String? slot}) async {
    final effectiveSlot = slot ?? await activeSlot(provider);
    if (effectiveSlot == null) return null;
    return _secretsStore.read(CredentialSlot(provider: provider, name: effectiveSlot).storeKey);
  }

  /// The secret-store reference key for a provider's active slot — this is
  /// what gets passed into `ProviderConfig.apiKeySecretRef`, so a
  /// `ModelProvider` never needs to know about slots or the vault at all,
  /// only a single opaque reference it resolves through the ordinary
  /// [SecretsStore].
  Future<String?> activeReferenceFor(String provider) async {
    final slot = await activeSlot(provider);
    return slot == null ? null : CredentialSlot(provider: provider, name: slot).storeKey;
  }
}
