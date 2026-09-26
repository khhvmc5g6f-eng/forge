import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/context/repo_index.dart';
import 'package:forge/core/context/repo_indexer.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('forge_repo_indexer_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  void write(String relativePath, String content) {
    final file = File(p.join(tempDir.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  test('indexes Dart classes and imports', () async {
    write('lib/core/tools/tool.dart', '''
import 'package:meta/meta.dart';
import '../security/untrusted_content.dart';

abstract class Tool {
  String get name;
}

class PatchFileTool {
  void execute() {}
}
''');
    write('lib/core/security/untrusted_content.dart', 'class UntrustedContent {}\n');

    final index = await RepoIndexer().build(tempDir.path);
    expect(index.fileCount, 2);

    final names = index.symbols.map((s) => s.name).toSet();
    expect(names, containsAll(['Tool', 'PatchFileTool', 'UntrustedContent']));

    final toolFile = 'lib/core/tools/tool.dart';
    final imports = index.importsOf(toolFile).map((i) => i.target).toSet();
    expect(imports, contains('package:meta/meta.dart'));
    expect(imports, contains('../security/untrusted_content.dart'));
  });

  test('skips ignored directories', () async {
    write('.dart_tool/generated.dart', 'class ShouldNotAppear {}\n');
    write('build/output.dart', 'class AlsoIgnored {}\n');
    write('lib/real.dart', 'class RealSymbol {}\n');

    final index = await RepoIndexer().build(tempDir.path);
    final names = index.symbols.map((s) => s.name).toSet();
    expect(names, contains('RealSymbol'));
    expect(names, isNot(contains('ShouldNotAppear')));
    expect(names, isNot(contains('AlsoIgnored')));
  });

  test('extracts Python classes, defs, and imports', () async {
    write('script.py', '''
import os
from pathlib import Path

class Runner:
    def execute(self):
        pass

def helper():
    pass
''');
    final index = await RepoIndexer().build(tempDir.path);
    final names = index.symbols.map((s) => s.name).toSet();
    expect(names, containsAll(['Runner', 'execute', 'helper']));
    final imports = index.importsOf('script.py').map((i) => i.target).toSet();
    expect(imports, containsAll(['os', 'pathlib']));
  });

  test('RepoSearch ranks an exact symbol match above a substring match', () async {
    write('lib/a.dart', 'class Widget {}\n');
    write('lib/b.dart', 'class MyWidgetHelper {}\n');
    final index = await RepoIndexer().build(tempDir.path);
    final results = RepoSearch(index).search('Widget');
    expect(results.first.matchedSymbol?.name, 'Widget');
  });

  test('dependentsOf finds reverse-dependency edges', () async {
    write('lib/core/a.dart', "import '../core/b.dart';\nclass A {}\n");
    write('lib/core/b.dart', 'class B {}\n');
    final index = await RepoIndexer().build(tempDir.path);
    expect(index.dependentsOf('../core/b.dart'), contains('lib/core/a.dart'));
  });
}
