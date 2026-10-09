/// Neural Observatory — telemetry persistence.
///
/// JSONL files under `<project>/.forge/observability/`, following the same
/// plain-file convention as `FileTaskStore`: legible, git-excludable, and
/// sufficient at workstation scale. Bounded and batched — `append` only
/// queues, `flush` writes — so telemetry can never stall the request path,
/// and a full queue degrades by dropping oldest events (counted, reported)
/// rather than by failing the caller.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'telemetry.dart';

abstract class TelemetryStore {
  Future<void> append(ObsSpan span);

  /// Drains the queued events to disk. Errors are counted in
  /// [writeFailures] and swallowed: a broken store degrades the
  /// Observatory's history, never the application it measures.
  Future<void> flush();

  /// Every retained event, oldest first, skipping corrupt lines the same
  /// way `FileTaskStore.loadAll` does.
  Future<List<Map<String, dynamic>>> readAll();

  /// Writes that failed since construction — surfaced in the UI as a
  /// "telemetry collection health" indicator.
  int get writeFailures;

  /// Events dropped because the queue was full (backpressure policy).
  int get droppedEvents;

  int get pendingCount;
}

class JsonlTelemetryStore implements TelemetryStore {
  JsonlTelemetryStore(
    this.projectRoot, {
    this.maxLinesPerFile = 20000,
    this.maxFiles = 3,
    this.maxQueued = 10000,
    this.flushThreshold = 64,
  });

  /// The open project's root; files live in `.forge/observability/`.
  final String projectRoot;
  final int maxLinesPerFile;

  /// Retention: total files kept. Rotation deletes the oldest — the
  /// raw-event retention policy from the data-architecture requirements.
  final int maxFiles;
  final int maxQueued;
  final int flushThreshold;

  final List<String> _queue = [];
  int _writeFailures = 0;
  int _dropped = 0;

  @override
  int get writeFailures => _writeFailures;

  @override
  int get droppedEvents => _dropped;

  @override
  int get pendingCount => _queue.length;

  Directory get _dir =>
      Directory(p.join(projectRoot, '.forge', 'observability'));

  List<File> _files() {
    if (!_dir.existsSync()) return const [];
    return _dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  }

  @override
  Future<void> append(ObsSpan span) async {
    // Redaction happens here, at the boundary, so no caller can forget it.
    final map = span.toJson();
    map['attributes'] = redactAttributes(span.attributes);
    _queue.add(jsonEncode(map));
    if (_queue.length > maxQueued) {
      _queue.removeAt(0);
      _dropped++;
    }
    if (_queue.length >= flushThreshold) {
      await flush();
    }
  }

  @override
  Future<void> flush() async {
    if (_queue.isEmpty) return;
    final lines = List<String>.of(_queue);
    _queue.clear();
    try {
      if (!_dir.existsSync()) _dir.createSync(recursive: true);
      var remaining = lines;
      // Write in chunks that respect maxLinesPerFile, so a single large
      // flush cannot blow past the retention bound.
      while (remaining.isNotEmpty) {
        var files = _files();
        if (files.isEmpty || _lineCount(files.last) >= maxLinesPerFile) {
          files = [...files, _newFile()];
        }
        final target = files.last;
        final capacity = maxLinesPerFile - _lineCount(target);
        final chunk = remaining.take(capacity).toList();
        remaining = remaining.skip(chunk.length).toList();
        final sink = File(target.path).openWrite(mode: FileMode.append);
        sink.writeAll(chunk, '\n');
        await sink.flush();
        await sink.close();
        await _rotateIfNeeded();
      }
    } catch (_) {
      // Re-queue so a transient disk failure does not silently lose
      // history; maxQueued still bounds growth (oldest dropped, counted).
      _queue.insertAll(0, lines);
      while (_queue.length > maxQueued) {
        _queue.removeAt(0);
        _dropped++;
      }
      _writeFailures++;
    }
  }

  File _newFile() {
    _fileCounter++;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file =
        File(p.join(_dir.path, 'events-$stamp-$_fileCounter.jsonl'));
    file.createSync();
    return file;
  }

  int _fileCounter = 0;

  int _lineCount(File f) {
    if (!f.existsSync()) return 0;
    return f.readAsLinesSync().where((l) => l.trim().isNotEmpty).length;
  }

  Future<void> _rotateIfNeeded() async {
    final files = _files();
    while (files.length > maxFiles) {
      await files.first.delete();
      files.removeAt(0);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async {
    final events = <Map<String, dynamic>>[];
    for (final file in _files()) {
      if (!file.existsSync()) continue;
      final lines = await file.readAsLines();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          events.add(jsonDecode(trimmed) as Map<String, dynamic>);
        } catch (_) {
          // Corrupt/partial line from a crash mid-write: skip, don't fail.
        }
      }
    }
    return events;
  }
}
