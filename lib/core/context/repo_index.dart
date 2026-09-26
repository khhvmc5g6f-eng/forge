import 'package:meta/meta.dart';

enum SymbolKind { class_, mixin_, enum_, extension_, function, topLevelVariable }

@immutable
class SymbolEntry {
  const SymbolEntry({
    required this.file,
    required this.name,
    required this.kind,
    required this.line,
  });

  final String file;
  final String name;
  final SymbolKind kind;
  final int line;
}

@immutable
class ImportEntry {
  const ImportEntry({required this.file, required this.target});

  /// The file containing the import statement.
  final String file;

  /// The import's raw target string (e.g. `package:forge/core/tools/tool.dart`,
  /// `./sibling.dart`, `os` for a Python `import os`).
  final String target;
}

@immutable
class IndexedFile {
  const IndexedFile({required this.path, required this.language, required this.sizeBytes});

  final String path;
  final String language;
  final int sizeBytes;
}

/// The result of indexing a repository: every scanned file, every symbol
/// declaration found in it, and every import edge — the data backing the
/// brief's Repository Intelligence layer ("index files, symbols, classes,
/// functions, dependencies, imports").
class RepoIndex {
  RepoIndex({
    required this.root,
    required this.files,
    required this.symbols,
    required this.imports,
    required this.builtAt,
  });

  final String root;
  final List<IndexedFile> files;
  final List<SymbolEntry> symbols;
  final List<ImportEntry> imports;
  final DateTime builtAt;

  int get fileCount => files.length;
  int get symbolCount => symbols.length;

  List<SymbolEntry> symbolsIn(String file) => symbols.where((s) => s.file == file).toList();

  List<ImportEntry> importsOf(String file) => imports.where((i) => i.file == file).toList();

  /// Files that import [file] (by exact resolved target match) — the
  /// reverse-dependency direction, useful for "what would this change
  /// affect?" queries.
  List<String> dependentsOf(String file) =>
      imports.where((i) => i.target == file).map((i) => i.file).toSet().toList();
}

@immutable
class RepoSearchResult {
  const RepoSearchResult({required this.file, required this.score, this.matchedSymbol});

  final String file;
  final double score;
  final SymbolEntry? matchedSymbol;
}

/// Ranked, lexical search over a [RepoIndex] — deliberately not a full
/// semantic/embedding search (that requires an embedding model and a vector
/// store, tracked separately). A symbol-name exact match ranks highest, a
/// symbol-name substring match next, then a bare filename match — cheap,
/// dependency-free, and good enough to avoid ever sending a whole repository
/// to a model, per RESEARCH_FINDINGS.md's rejection of that pattern.
class RepoSearch {
  RepoSearch(this.index);

  final RepoIndex index;

  List<RepoSearchResult> search(String query, {int limit = 20}) {
    final needle = query.toLowerCase();
    if (needle.isEmpty) return const [];
    final results = <RepoSearchResult>[];

    for (final symbol in index.symbols) {
      final name = symbol.name.toLowerCase();
      if (name == needle) {
        results.add(RepoSearchResult(file: symbol.file, score: 100, matchedSymbol: symbol));
      } else if (name.contains(needle)) {
        results.add(RepoSearchResult(file: symbol.file, score: 60, matchedSymbol: symbol));
      }
    }
    for (final file in index.files) {
      final base = file.path.split('/').last.toLowerCase();
      if (base.contains(needle)) {
        results.add(RepoSearchResult(file: file.path, score: 30));
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(limit).toList();
  }
}
