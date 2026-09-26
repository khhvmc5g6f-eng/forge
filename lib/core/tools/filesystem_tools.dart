import 'dart:io';

import 'package:path/path.dart' as p;

import '../security/untrusted_content.dart';
import 'policy_engine.dart';
import 'tool.dart';
import 'tool_category.dart';

/// Common base for every filesystem [Tool]: resolves a `path` argument to an
/// absolute path under [projectRoot] and reports it as the invocation's
/// [ToolInvocation.targetPath] so [PolicyEngine] enforces the sandbox
/// boundary before any I/O happens.
abstract class _FilesystemTool implements Tool {
  _FilesystemTool(this.projectRoot);

  final String projectRoot;

  @override
  ToolCategory get category => ToolCategory.filesystem;

  String resolve(String relativeOrAbsolute) {
    return p.isAbsolute(relativeOrAbsolute)
        ? p.normalize(relativeOrAbsolute)
        : p.normalize(p.join(projectRoot, relativeOrAbsolute));
  }

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) {
    final path = resolve(arguments['path'] as String? ?? projectRoot);
    return ToolInvocation(
      category: category,
      toolName: name,
      targetPath: path,
      description: '$name($path)',
    );
  }
}

class ListDirectoryTool extends _FilesystemTool {
  ListDirectoryTool(super.projectRoot);

  @override
  String get name => 'list_directory';

  @override
  String get description => 'Lists files and subdirectories under a path.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'recursive': {'type': 'boolean'},
        },
        'required': ['path'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final dir = Directory(resolve(arguments['path'] as String));
    final recursive = arguments['recursive'] as bool? ?? false;
    if (!dir.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${dir.path}');
    }
    final entries = dir.listSync(recursive: recursive);
    final lines = entries.map((e) {
      final type = e is Directory ? 'dir' : 'file';
      return '$type\t${p.relative(e.path, from: projectRoot)}';
    }).toList()
      ..sort();
    return UntrustedContent(source: ContentSource.fileContent, body: lines.join('\n'));
  }
}

class ReadFileTool extends _FilesystemTool {
  ReadFileTool(super.projectRoot);

  @override
  String get name => 'read_file';

  @override
  String get description => 'Reads the full contents of a text file.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final file = File(resolve(arguments['path'] as String));
    if (!file.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${file.path}');
    }
    return UntrustedContent(
        source: ContentSource.fileContent, body: await file.readAsString());
  }
}

class ReadRangeTool extends _FilesystemTool {
  ReadRangeTool(super.projectRoot);

  @override
  String get name => 'read_range';

  @override
  String get description => 'Reads a 1-indexed inclusive line range of a text file.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'start_line': {'type': 'integer'},
          'end_line': {'type': 'integer'},
        },
        'required': ['path', 'start_line', 'end_line'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final file = File(resolve(arguments['path'] as String));
    if (!file.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${file.path}');
    }
    final lines = await file.readAsLines();
    final start = ((arguments['start_line'] as num).toInt() - 1).clamp(0, lines.length);
    final end = (arguments['end_line'] as num).toInt().clamp(0, lines.length);
    return UntrustedContent(
      source: ContentSource.fileContent,
      body: lines.sublist(start, end).join('\n'),
    );
  }
}

class ReadMultipleFilesTool extends _FilesystemTool {
  ReadMultipleFilesTool(super.projectRoot);

  @override
  String get name => 'read_multiple_files';

  @override
  String get description => 'Reads several text files in one call.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'paths': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': ['paths'],
      };

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) {
    final paths = (arguments['paths'] as List).cast<String>().map(resolve);
    return ToolInvocation(
      category: category,
      toolName: name,
      targetPath: paths.isEmpty ? projectRoot : paths.first,
      description: 'read_multiple_files(${paths.length} files)',
    );
  }

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final paths = (arguments['paths'] as List).cast<String>();
    final buffer = StringBuffer();
    for (final path in paths) {
      final file = File(resolve(path));
      buffer.writeln('--- $path ---');
      buffer.writeln(file.existsSync() ? await file.readAsString() : 'ERROR: not found');
    }
    return UntrustedContent(source: ContentSource.fileContent, body: buffer.toString());
  }
}

class CreateFileTool extends _FilesystemTool {
  CreateFileTool(super.projectRoot);

  @override
  String get name => 'create_file';

  @override
  String get description => 'Creates a new file (fails if it already exists).';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'content': {'type': 'string'},
        },
        'required': ['path', 'content'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final file = File(resolve(arguments['path'] as String));
    if (file.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: already exists: ${file.path}');
    }
    await file.create(recursive: true);
    await file.writeAsString(arguments['content'] as String);
    return UntrustedContent(source: ContentSource.toolResult, body: 'Created ${file.path}');
  }
}

/// A single anchored replacement, applied deterministically rather than as a
/// free-form file rewrite — per RESEARCH_FINDINGS.md, this lets the tool
/// (not the model) verify the anchor actually matches before writing.
class PatchFileTool extends _FilesystemTool {
  PatchFileTool(super.projectRoot);

  @override
  String get name => 'patch_file';

  @override
  String get description =>
      'Replaces one exact occurrence of `find` with `replace` in a file.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'find': {'type': 'string'},
          'replace': {'type': 'string'},
        },
        'required': ['path', 'find', 'replace'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final file = File(resolve(arguments['path'] as String));
    if (!file.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${file.path}');
    }
    final content = await file.readAsString();
    final find = arguments['find'] as String;
    final occurrences = find.isEmpty ? 0 : find.allMatches(content).length;
    if (occurrences == 0) {
      return UntrustedContent(
          source: ContentSource.toolResult,
          body: 'ERROR: anchor text not found in ${file.path}');
    }
    if (occurrences > 1) {
      return UntrustedContent(
        source: ContentSource.toolResult,
        body: 'ERROR: anchor text is not unique ($occurrences matches) in '
            '${file.path}; widen the anchor.',
      );
    }
    final updated = content.replaceFirst(find, arguments['replace'] as String);
    await file.writeAsString(updated);
    return UntrustedContent(source: ContentSource.toolResult, body: 'Patched ${file.path}');
  }
}

class RenameFileTool extends _FilesystemTool {
  RenameFileTool(super.projectRoot);

  @override
  String get name => 'rename_file';

  @override
  String get description => 'Renames or moves a file within the sandbox.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'new_path': {'type': 'string'},
        },
        'required': ['path', 'new_path'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final file = File(resolve(arguments['path'] as String));
    final newPath = resolve(arguments['new_path'] as String);
    if (!file.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${file.path}');
    }
    await Directory(p.dirname(newPath)).create(recursive: true);
    await file.rename(newPath);
    return UntrustedContent(
        source: ContentSource.toolResult, body: 'Renamed to $newPath');
  }
}

class DeleteFileTool extends _FilesystemTool {
  DeleteFileTool(super.projectRoot);

  @override
  String get name => 'delete_file';

  @override
  String get description => 'Deletes a file within the sandbox.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final file = File(resolve(arguments['path'] as String));
    if (!file.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${file.path}');
    }
    await file.delete();
    return UntrustedContent(source: ContentSource.toolResult, body: 'Deleted ${file.path}');
  }
}

class CompareFilesTool extends _FilesystemTool {
  CompareFilesTool(super.projectRoot);

  @override
  String get name => 'compare_files';

  @override
  String get description => 'Reports whether two files are byte-identical and a line-level diff summary.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'other_path': {'type': 'string'},
        },
        'required': ['path', 'other_path'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final a = File(resolve(arguments['path'] as String));
    final b = File(resolve(arguments['other_path'] as String));
    if (!a.existsSync() || !b.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: one or both files not found');
    }
    final aLines = await a.readAsLines();
    final bLines = await b.readAsLines();
    if (aLines.join('\n') == bLines.join('\n')) {
      return UntrustedContent(source: ContentSource.toolResult, body: 'IDENTICAL');
    }
    final maxLen = aLines.length > bLines.length ? aLines.length : bLines.length;
    var differing = 0;
    for (var i = 0; i < maxLen; i++) {
      final left = i < aLines.length ? aLines[i] : null;
      final right = i < bLines.length ? bLines[i] : null;
      if (left != right) differing++;
    }
    return UntrustedContent(
      source: ContentSource.toolResult,
      body: 'DIFFERS: $differing differing line(s) out of $maxLen',
    );
  }
}

/// Text search across files under a root, restricted to the sandbox. A real
/// deployment should shell out to `rg`/`grep` for performance on large
/// repositories (see core/context — Repository Indexer); this pure-Dart
/// implementation keeps the tool dependency-free and fully testable in any
/// environment.
class SearchFilesTool extends _FilesystemTool {
  SearchFilesTool(super.projectRoot);

  @override
  String get name => 'search_files';

  @override
  String get description => 'Finds files whose name matches a glob-like substring pattern.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'name_contains': {'type': 'string'},
        },
        'required': ['path', 'name_contains'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final root = Directory(resolve(arguments['path'] as String));
    final needle = arguments['name_contains'] as String;
    if (!root.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${root.path}');
    }
    final matches = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.basename(f.path).contains(needle))
        .map((f) => p.relative(f.path, from: projectRoot))
        .toList()
      ..sort();
    return UntrustedContent(source: ContentSource.fileContent, body: matches.join('\n'));
  }
}

class SearchCodeTool extends _FilesystemTool {
  SearchCodeTool(super.projectRoot);

  @override
  String get name => 'search_code';

  @override
  String get description => 'Finds lines matching a literal substring across text files under a path.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'query': {'type': 'string'},
          'max_results': {'type': 'integer'},
        },
        'required': ['path', 'query'],
      };

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final root = Directory(resolve(arguments['path'] as String));
    final query = arguments['query'] as String;
    final maxResults = (arguments['max_results'] as num?)?.toInt() ?? 200;
    if (!root.existsSync()) {
      return UntrustedContent(
          source: ContentSource.toolResult, body: 'ERROR: not found: ${root.path}');
    }
    final results = <String>[];
    for (final entity in root.listSync(recursive: true)) {
      if (results.length >= maxResults) break;
      if (entity is! File) continue;
      if (_isBinaryLikePath(entity.path)) continue;
      List<String> lines;
      try {
        lines = await entity.readAsLines();
      } catch (_) {
        continue;
      }
      for (var i = 0; i < lines.length; i++) {
        if (results.length >= maxResults) break;
        if (lines[i].contains(query)) {
          final rel = p.relative(entity.path, from: projectRoot);
          results.add('$rel:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    return UntrustedContent(source: ContentSource.fileContent, body: results.join('\n'));
  }

  static const _binaryExtensions = {
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.gz', '.woff',
    '.woff2', '.ttf', '.otf', '.so', '.dylib', '.dll', '.exe', '.class',
  };

  bool _isBinaryLikePath(String path) => _binaryExtensions.contains(p.extension(path));
}

/// Registers the full filesystem tool set on a [ToolGateway]-compatible
/// registrar (kept separate from [ToolGateway] to avoid a circular import;
/// callers pass `gateway.register`).
void registerFilesystemTools(void Function(Tool) register, String projectRoot) {
  register(ListDirectoryTool(projectRoot));
  register(SearchFilesTool(projectRoot));
  register(SearchCodeTool(projectRoot));
  register(ReadFileTool(projectRoot));
  register(ReadRangeTool(projectRoot));
  register(ReadMultipleFilesTool(projectRoot));
  register(CreateFileTool(projectRoot));
  register(PatchFileTool(projectRoot));
  register(RenameFileTool(projectRoot));
  register(DeleteFileTool(projectRoot));
  register(CompareFilesTool(projectRoot));
}
