import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/memory/memory_entry.dart';
import 'package:forge/core/memory/memory_store.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('forge_memory_store_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('record() persists and loadAll() reads it back', () async {
    final store = MemoryStore(tempDir.path);
    final entry = await store.record(
      kind: MemoryKind.knownIssue,
      title: 'Cockpit high CPU',
      body: 'ROOT CAUSE: repeated listener registration\nPATCH: dedupe registration\nRESULT: resolved',
      tags: ['cockpit', 'performance'],
    );

    final loaded = await store.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.id, entry.id);
    expect(loaded.first.title, 'Cockpit high CPU');
    expect(loaded.first.tags, contains('performance'));
  });

  test('a second MemoryStore instance on the same directory sees prior entries', () async {
    final first = MemoryStore(tempDir.path);
    await first.record(kind: MemoryKind.buildCommand, title: 'Build', body: 'flutter build macos');

    final second = MemoryStore(tempDir.path);
    final loaded = await second.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.first.kind, MemoryKind.buildCommand);
  });

  test('search ranks a tag match above a body-only match', () async {
    final store = MemoryStore(tempDir.path);
    await store.record(
      kind: MemoryKind.knownIssue,
      title: 'Unrelated title',
      body: 'mentions cpu in passing',
      tags: [],
    );
    await store.record(
      kind: MemoryKind.knownIssue,
      title: 'Cockpit issue',
      body: 'nothing relevant here',
      tags: ['cpu'],
    );

    final results = await store.search('cpu');
    expect(results.first.title, 'Cockpit issue');
  });

  test('delete removes an entry', () async {
    final store = MemoryStore(tempDir.path);
    final entry = await store.record(kind: MemoryKind.priorFix, title: 'x', body: 'y');
    await store.delete(entry.id);
    expect(await store.loadAll(), isEmpty);
  });

  test('loadAll returns empty list when no memory file exists yet', () async {
    final store = MemoryStore(tempDir.path);
    expect(await store.loadAll(), isEmpty);
  });
}
