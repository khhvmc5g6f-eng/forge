import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'task.dart';

/// Persistence for [Task]s. The concrete requirement driving this is TEST 25
/// in the acceptance suite: "Recover an interrupted task after restarting
/// the application" — [Task] state must survive a process restart, so it is
/// never held only in memory.
abstract class TaskStore {
  Future<void> save(Task task);
  Future<Task?> load(String taskId);
  Future<List<Task>> loadAll();
  Future<void> delete(String taskId);
}

/// Writes one JSON file per task under `<project>/.forge/tasks/<id>.json`.
/// Plain files rather than a database: legible with any text editor, easy to
/// exclude from Git (`.forge/` is a local, per-project data directory — see
/// RECOVERY.md), and sufficient at the scale of "a handful of concurrent
/// tasks per project".
class FileTaskStore implements TaskStore {
  FileTaskStore(this.projectRoot);

  final String projectRoot;

  Directory get _dir => Directory(p.join(projectRoot, '.forge', 'tasks'));

  File _fileFor(String taskId) => File(p.join(_dir.path, '$taskId.json'));

  @override
  Future<void> save(Task task) async {
    if (!_dir.existsSync()) {
      _dir.createSync(recursive: true);
    }
    task.updatedAt = DateTime.now();
    await _fileFor(task.id).writeAsString(jsonEncode(task.toJson()));
  }

  @override
  Future<Task?> load(String taskId) async {
    final file = _fileFor(taskId);
    if (!file.existsSync()) return null;
    return Task.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
  }

  @override
  Future<List<Task>> loadAll() async {
    if (!_dir.existsSync()) return [];
    final files = _dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    final tasks = <Task>[];
    for (final file in files) {
      try {
        tasks.add(Task.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // Corrupt/partial write from a crash mid-save: skip rather than
        // fail the whole resume flow.
      }
    }
    tasks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return tasks;
  }

  @override
  Future<void> delete(String taskId) async {
    final file = _fileFor(taskId);
    if (file.existsSync()) await file.delete();
  }
}

/// In-memory store for tests.
class InMemoryTaskStore implements TaskStore {
  final Map<String, Task> _tasks = {};

  @override
  Future<void> save(Task task) async {
    task.updatedAt = DateTime.now();
    _tasks[task.id] = task;
  }

  @override
  Future<Task?> load(String taskId) async => _tasks[taskId];

  @override
  Future<List<Task>> loadAll() async =>
      _tasks.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> delete(String taskId) async {
    _tasks.remove(taskId);
  }
}
