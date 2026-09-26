import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'recent_project.dart';

/// Tracks the workstation's recently-opened projects across the whole
/// application (not per-project), enabling the brief's "Open Project / Open
/// Folder / Clone GitHub Repository / Recent Projects" flow, and — the
/// point of tracking it centrally rather than per-project — genuine
/// multi-project switching: each project's own state (`TaskManager`,
/// `GitService`, `MemoryStore`, MCP config) is already fully parameterised
/// by its root path (see `lib/app/forge_providers.dart`), so switching the
/// active project here is exactly the `projectRootProvider` state change and
/// nothing more needs to be torn down or reset.
///
/// Stored at `<configDir>/projects.json`, defaulting to
/// `~/.forge/global/projects.json` — a workstation-wide location, distinct
/// from any single project's own `.forge/` directory.
class ProjectManager {
  ProjectManager({String? configDir}) : _configDir = configDir ?? _defaultConfigDir();

  final String _configDir;

  static String _defaultConfigDir() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return p.join(home, '.forge', 'global');
  }

  File get _file => File(p.join(_configDir, 'projects.json'));

  Future<List<RecentProject>> listRecent() async {
    if (!_file.existsSync()) return [];
    try {
      final raw = jsonDecode(await _file.readAsString()) as List<dynamic>;
      final projects =
          raw.map((e) => RecentProject.fromJson(e as Map<String, dynamic>)).toList();
      projects.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
      return projects;
    } catch (_) {
      return [];
    }
  }

  /// Opens [path] — validates it exists, records/refreshes it in the recent
  /// list, and returns the normalised absolute path the caller should set as
  /// the active project root.
  Future<String> open(String path) async {
    final normalized = p.normalize(p.absolute(path));
    if (!Directory(normalized).existsSync()) {
      throw ProjectNotFoundException(normalized);
    }
    final projects = await listRecent();
    projects.removeWhere((p) => p.path == normalized);
    projects.insert(0, RecentProject(path: normalized, lastOpenedAt: DateTime.now()));
    await _persist(projects.take(20).toList());
    return normalized;
  }

  Future<void> forget(String path) async {
    final normalized = p.normalize(p.absolute(path));
    final projects = await listRecent();
    projects.removeWhere((p) => p.path == normalized);
    await _persist(projects);
  }

  Future<void> _persist(List<RecentProject> projects) async {
    if (!_file.parent.existsSync()) {
      _file.parent.createSync(recursive: true);
    }
    await _file.writeAsString(jsonEncode(projects.map((p) => p.toJson()).toList()));
  }
}

class ProjectNotFoundException implements Exception {
  ProjectNotFoundException(this.path);
  final String path;
  @override
  String toString() => 'No such directory: $path';
}
