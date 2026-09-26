import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'memory_entry.dart';

/// Persistent, per-project memory: `<project>/.forge/memory.json`, a single
/// JSON array (memory volume per project is small enough — hundreds to a
/// few thousand entries — that one file beats one-file-per-entry here,
/// unlike [TaskStore]'s one-file-per-task choice, which needs to tolerate
/// partial writes on individual in-flight tasks).
class MemoryStore {
  MemoryStore(this.projectRoot) : _uuid = const Uuid();

  final String projectRoot;
  final Uuid _uuid;

  File get _file => File(p.join(projectRoot, '.forge', 'memory.json'));

  Future<List<MemoryEntry>> loadAll() async {
    if (!_file.existsSync()) return [];
    try {
      final raw = jsonDecode(await _file.readAsString()) as List<dynamic>;
      return raw.map((e) => MemoryEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<MemoryEntry> record({
    required MemoryKind kind,
    required String title,
    required String body,
    List<String> tags = const [],
    String? taskId,
  }) async {
    final entries = await loadAll();
    final entry = MemoryEntry(
      id: 'mem_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}',
      kind: kind,
      title: title,
      body: body,
      createdAt: DateTime.now(),
      tags: tags,
      taskId: taskId,
    );
    entries.add(entry);
    await _persist(entries);
    return entry;
  }

  Future<void> delete(String id) async {
    final entries = await loadAll();
    entries.removeWhere((e) => e.id == id);
    await _persist(entries);
  }

  Future<void> _persist(List<MemoryEntry> entries) async {
    if (!_file.parent.existsSync()) {
      _file.parent.createSync(recursive: true);
    }
    await _file.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  /// Simple relevance search over title/body/tags — the retrieval half of
  /// "later similar problems should retrieve this evidence." Ranks a tag
  /// match above a title match above a body match; this is intentionally
  /// the same lexical-ranking philosophy as `RepoSearch`, not a semantic
  /// embedding search (tracked separately, see NVIDIA.md's embedding model
  /// note).
  Future<List<MemoryEntry>> search(String query, {int limit = 10}) async {
    final needle = query.toLowerCase();
    if (needle.isEmpty) return const [];
    final entries = await loadAll();
    final scored = <MapEntry<MemoryEntry, double>>[];
    for (final entry in entries) {
      double score = 0;
      if (entry.tags.any((t) => t.toLowerCase() == needle)) score += 50;
      if (entry.tags.any((t) => t.toLowerCase().contains(needle))) score += 20;
      if (entry.title.toLowerCase().contains(needle)) score += 30;
      if (entry.body.toLowerCase().contains(needle)) score += 10;
      if (score > 0) scored.add(MapEntry(entry, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.take(limit).map((e) => e.key).toList();
  }
}
