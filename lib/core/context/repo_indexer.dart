import 'dart:io';

import 'package:path/path.dart' as p;

import 'repo_index.dart';

/// Builds a [RepoIndex] by walking the project tree once. This is a
/// lightweight, regex-based scanner deliberately kept dependency-free rather
/// than a full per-language AST parser (`analyzer`/tree-sitter) — it trades
/// perfect precision for zero build-time cost and broad language coverage,
/// matching Aider's "repo map" pattern from RESEARCH_FINDINGS.md: a cheap
/// structural summary beats sending full source, and beats sending nothing.
class RepoIndexer {
  RepoIndexer({this.maxFileBytes = 2 * 1024 * 1024});

  final int maxFileBytes;

  static const _ignoredDirNames = {
    '.git', '.dart_tool', 'build', '.idea', 'node_modules', '.pub-cache',
    'Pods', 'DerivedData', '.gradle', '.forge', 'ios', 'android',
  };

  static const Map<String, String> _languageByExtension = {
    '.dart': 'dart',
    '.js': 'javascript',
    '.jsx': 'javascript',
    '.ts': 'typescript',
    '.tsx': 'typescript',
    '.py': 'python',
    '.go': 'go',
    '.rs': 'rust',
    '.java': 'java',
    '.kt': 'kotlin',
    '.swift': 'swift',
    '.c': 'c',
    '.cpp': 'cpp',
    '.h': 'c',
  };

  Future<RepoIndex> build(String root) async {
    final files = <IndexedFile>[];
    final symbols = <SymbolEntry>[];
    final imports = <ImportEntry>[];

    await for (final entity in Directory(root).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root);
      if (_isIgnored(relative)) continue;

      final extension = p.extension(entity.path);
      final language = _languageByExtension[extension];
      if (language == null) continue;

      final stat = await entity.stat();
      if (stat.size > maxFileBytes) continue;
      files.add(IndexedFile(path: relative, language: language, sizeBytes: stat.size));

      String content;
      try {
        content = await entity.readAsString();
      } catch (_) {
        continue; // binary or undecodable despite the extension match
      }

      symbols.addAll(_extractSymbols(relative, language, content));
      imports.addAll(_extractImports(relative, language, content));
    }

    return RepoIndex(root: root, files: files, symbols: symbols, imports: imports, builtAt: DateTime.now());
  }

  bool _isIgnored(String relativePath) {
    final segments = p.split(relativePath);
    return segments.any(_ignoredDirNames.contains);
  }

  static final _dartTypeDecl =
      RegExp(r'^\s*(?:abstract\s+)?(class|mixin|enum|extension)\s+(\w+)');
  static final _dartTopLevelFunction =
      RegExp(r'^(?:Future<[\w<>,\s?]*>|Stream<[\w<>,\s?]*>|void|[A-Z]\w*(?:<[\w<>,\s?]*>)?|int|double|bool|String|dynamic|var)\s+(\w+)\s*\(');
  static final _jsClassDecl = RegExp(r'^\s*(?:export\s+)?class\s+(\w+)');
  static final _jsFunctionDecl =
      RegExp(r'^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(');
  static final _pythonDef = RegExp(r'^\s*(?:async\s+)?def\s+(\w+)\s*\(');
  static final _pythonClass = RegExp(r'^\s*class\s+(\w+)');

  List<SymbolEntry> _extractSymbols(String file, String language, String content) {
    final results = <SymbolEntry>[];
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      switch (language) {
        case 'dart':
          final typeMatch = _dartTypeDecl.firstMatch(line);
          if (typeMatch != null) {
            results.add(SymbolEntry(
              file: file,
              name: typeMatch.group(2)!,
              kind: _dartKindFor(typeMatch.group(1)!),
              line: i + 1,
            ));
            continue;
          }
          final fnMatch = _dartTopLevelFunction.firstMatch(line);
          if (fnMatch != null && !line.trimLeft().startsWith('//')) {
            results.add(SymbolEntry(
              file: file,
              name: fnMatch.group(1)!,
              kind: SymbolKind.function,
              line: i + 1,
            ));
          }
        case 'javascript':
        case 'typescript':
          final classMatch = _jsClassDecl.firstMatch(line);
          if (classMatch != null) {
            results.add(SymbolEntry(
                file: file, name: classMatch.group(1)!, kind: SymbolKind.class_, line: i + 1));
            continue;
          }
          final fnMatch = _jsFunctionDecl.firstMatch(line);
          if (fnMatch != null) {
            results.add(SymbolEntry(
                file: file, name: fnMatch.group(1)!, kind: SymbolKind.function, line: i + 1));
          }
        case 'python':
          final classMatch = _pythonClass.firstMatch(line);
          if (classMatch != null) {
            results.add(SymbolEntry(
                file: file, name: classMatch.group(1)!, kind: SymbolKind.class_, line: i + 1));
            continue;
          }
          final defMatch = _pythonDef.firstMatch(line);
          if (defMatch != null) {
            results.add(SymbolEntry(
                file: file, name: defMatch.group(1)!, kind: SymbolKind.function, line: i + 1));
          }
      }
    }
    return results;
  }

  SymbolKind _dartKindFor(String keyword) {
    switch (keyword) {
      case 'class':
        return SymbolKind.class_;
      case 'mixin':
        return SymbolKind.mixin_;
      case 'enum':
        return SymbolKind.enum_;
      case 'extension':
        return SymbolKind.extension_;
      default:
        return SymbolKind.class_;
    }
  }

  static final _dartImport = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
  static final _jsImport = RegExp(r'''(?:from\s+['"]([^'"]+)['"]|require\(\s*['"]([^'"]+)['"]\s*\))''');
  static final _pythonImport = RegExp(r'^\s*(?:from\s+(\S+)\s+import|import\s+(\S+))');

  List<ImportEntry> _extractImports(String file, String language, String content) {
    final results = <ImportEntry>[];
    for (final line in content.split('\n')) {
      switch (language) {
        case 'dart':
          final match = _dartImport.firstMatch(line);
          if (match != null) {
            results.add(ImportEntry(file: file, target: match.group(1)!));
          }
        case 'javascript':
        case 'typescript':
          final match = _jsImport.firstMatch(line);
          if (match != null) {
            results.add(ImportEntry(file: file, target: (match.group(1) ?? match.group(2))!));
          }
        case 'python':
          final match = _pythonImport.firstMatch(line);
          if (match != null) {
            results.add(ImportEntry(file: file, target: (match.group(1) ?? match.group(2))!));
          }
      }
    }
    return results;
  }
}
