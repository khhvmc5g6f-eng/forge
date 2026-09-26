import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/memory/memory_entry.dart';

final memoryListProvider = FutureProvider.autoDispose<List<MemoryEntry>>((ref) async {
  return ref.watch(memoryStoreProvider).loadAll();
});

/// The Memory section: persistent project knowledge (architecture decisions,
/// known issues, prior fixes, conventions, ...) backed by
/// `.forge/memory.json` via [MemoryStore] — real storage and retrieval, not
/// a mock. The Repository Agent reads the same store when a task starts, so
/// entries recorded here are exactly what "later similar problems should
/// retrieve this evidence" means in this codebase.
class MemoryPanel extends ConsumerStatefulWidget {
  const MemoryPanel({super.key});

  @override
  ConsumerState<MemoryPanel> createState() => _MemoryPanelState();
}

class _MemoryPanelState extends ConsumerState<MemoryPanel> {
  final _searchController = TextEditingController();
  List<MemoryEntry>? _searchResults;

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(memoryListProvider);
    final entries = _searchResults ?? entriesAsync.valueOrNull ?? const [];

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Record memory'),
        onPressed: () => _showRecordDialog(context),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search memory (e.g. "cockpit cpu")',
                border: const OutlineInputBorder(),
                suffixIcon: _searchResults == null
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() {
                          _searchController.clear();
                          _searchResults = null;
                        }),
                      ),
              ),
              onSubmitted: (query) async {
                if (query.trim().isEmpty) {
                  setState(() => _searchResults = null);
                  return;
                }
                final results = await ref.read(memoryStoreProvider).search(query.trim());
                setState(() => _searchResults = results);
              },
            ),
          ),
          Expanded(
            child: entriesAsync.when(
              data: (_) => entries.isEmpty
                  ? const Center(child: Text('No memory recorded yet.'))
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) => _MemoryTile(entry: entries[index]),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, s) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showRecordDialog(BuildContext context) async {
    final titleController = TextEditingController();
    final bodyController = TextEditingController();
    final tagsController = TextEditingController();
    var kind = MemoryKind.knownIssue;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Record memory'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<MemoryKind>(
                value: kind,
                isExpanded: true,
                items: MemoryKind.values
                    .map((k) => DropdownMenuItem(value: k, child: Text(k.name)))
                    .toList(),
                onChanged: (v) => setDialogState(() => kind = v!),
              ),
              TextField(controller: titleController, decoration: const InputDecoration(labelText: 'Title')),
              TextField(
                controller: bodyController,
                decoration: const InputDecoration(labelText: 'Body'),
                maxLines: 4,
              ),
              TextField(
                controller: tagsController,
                decoration: const InputDecoration(labelText: 'Tags (comma-separated)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (saved == true && titleController.text.trim().isNotEmpty) {
      await ref.read(memoryStoreProvider).record(
            kind: kind,
            title: titleController.text.trim(),
            body: bodyController.text.trim(),
            tags: tagsController.text
                .split(',')
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList(),
          );
      ref.invalidate(memoryListProvider);
    }
  }
}

class _MemoryTile extends StatelessWidget {
  const _MemoryTile({required this.entry});
  final MemoryEntry entry;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.psychology_outlined),
      title: Text(entry.title),
      subtitle: Text('${entry.kind.name} · ${entry.tags.join(', ')}'),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Align(alignment: Alignment.centerLeft, child: Text(entry.body)),
        ),
      ],
    );
  }
}
