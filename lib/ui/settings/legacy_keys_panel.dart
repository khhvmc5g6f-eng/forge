import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/forge_engine/forge_engine.dart';
import '../engine/widgets.dart';

final legacyKeyMigrationProvider = Provider<LegacyKeyMigration>((ref) => LegacyKeyMigration(ref.watch(secretsStoreProvider)));

/// Provider keys an earlier build saved on this device, outside the engine vault.
final legacyKeysProvider = FutureProvider.autoDispose<List<LegacyKey>>((ref) => ref.watch(legacyKeyMigrationProvider).scan());

const _legacyColor = Color(0xFFE0A100);

/// Shown only when old keys exist on this device. They stay readable (the
/// legacy on-device model providers still read them) but are flagged and can
/// no longer be edited here; the way out is moving them into the engine vault.
class LegacyKeysPanel extends ConsumerWidget {
  const LegacyKeysPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(engineConnectionProvider);
    final keys = ref.watch(legacyKeysProvider).valueOrNull ?? const <LegacyKey>[];
    if (keys.isEmpty) return const SizedBox.shrink();
    final blocked = LegacyKeyMigration.blockedReason(conn);
    return Panel(
      title: 'Legacy keys on this device',
      subtitle: 'Saved by an earlier build outside the engine vault. They can no longer be edited here.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Note(
          'Provider credentials belong only in the engine vault. Moving a key sends it once to the engine; the old copy is deleted from this device only after the engine confirms it stored the key.',
          icon: Icons.shield_outlined,
        ),
        if (blocked != null) Padding(padding: const EdgeInsets.only(top: 8), child: Note(blocked, icon: Icons.lock_outline)),
        const SizedBox(height: 8),
        for (final k in keys) _LegacyRow(legacy: k, blocked: blocked),
      ]),
    );
  }
}

class _LegacyRow extends ConsumerWidget {
  const _LegacyRow({required this.legacy, required this.blocked});
  final LegacyKey legacy;
  final String? blocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(legacy.label, style: t.titleSmall)),
          const StatusPill('legacy — move to engine', _legacyColor, icon: Icons.history),
        ]),
        Text(legacy.tail.isEmpty ? 'stored (hidden)' : '••••${legacy.tail}', style: t.bodySmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          Tooltip(
            message: blocked ?? 'Send this key to the engine vault',
            child: FilledButton.icon(
              onPressed: blocked != null ? null : () => _move(context, ref),
              icon: const Icon(Icons.drive_file_move_outline, size: 16),
              label: const Text('Move to engine vault'),
            ),
          ),
          TextButton.icon(
            onPressed: () => _remove(context, ref),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Delete legacy copy'),
          ),
        ]),
      ]),
    );
  }

  Future<void> _move(BuildContext context, WidgetRef ref) async {
    final conn = ref.read(engineConnectionProvider);
    final providers = conn.state?.providers ?? const <EngineProvider>[];
    final choice = await showDialog<({String providerId, String name})>(
      context: context,
      builder: (_) => _MoveDialog(legacy: legacy, providers: providers),
    );
    if (choice == null || !context.mounted) return;
    final out = await ref.read(legacyKeyMigrationProvider).migrate(legacy, connection: conn, providerId: choice.providerId, name: choice.name);
    ref.invalidate(legacyKeysProvider);
    if (context.mounted) toast(context, out.message);
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(context,
        title: 'Delete the legacy ${legacy.label} key?',
        message: 'The old copy is removed from this device\'s secure storage. If it is not in the engine vault, you will need to enter it there again. This cannot be undone.',
        action: 'Delete',
        destructive: true);
    if (!ok || !context.mounted) return;
    final out = await ref.read(legacyKeyMigrationProvider).removeLegacy(legacy);
    ref.invalidate(legacyKeysProvider);
    if (context.mounted) toast(context, out.message);
  }
}

class _MoveDialog extends StatefulWidget {
  const _MoveDialog({required this.legacy, required this.providers});
  final LegacyKey legacy;
  final List<EngineProvider> providers;

  @override
  State<_MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<_MoveDialog> {
  late String? _provider = guessProvider(widget.legacy, widget.providers)?.id;
  final _name = TextEditingController(text: 'migrated');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final guessed = guessProvider(widget.legacy, widget.providers) != null;
    return AlertDialog(
      title: Text('Move ${widget.legacy.label} key to the engine?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('The key ending ${widget.legacy.tail.isEmpty ? '(hidden)' : '••••${widget.legacy.tail}'} will be sent once to the engine vault and stored in its OS credential store. '
              'Afterwards the copy on this device is deleted, but only if the engine confirms it stored the key.'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _provider,
            decoration: InputDecoration(labelText: 'Engine provider', helperText: guessed ? null : 'No provider matched automatically: choose one.'),
            items: [for (final p in widget.providers) DropdownMenuItem(value: p.id, child: Text(p.name))],
            onChanged: (v) => setState(() => _provider = v),
          ),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Key name in the vault'), onChanged: (_) => setState(() {})),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _provider == null || _name.text.trim().isEmpty ? null : () => Navigator.pop(context, (providerId: _provider!, name: _name.text.trim())),
          child: const Text('Move key'),
        ),
      ],
    );
  }
}
