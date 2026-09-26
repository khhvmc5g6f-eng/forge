import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/project/project_manager.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory configDir;
  late Directory projectA;
  late Directory projectB;

  setUp(() {
    configDir = Directory.systemTemp.createTempSync('forge_project_manager_config');
    projectA = Directory.systemTemp.createTempSync('forge_project_a');
    projectB = Directory.systemTemp.createTempSync('forge_project_b');
  });

  tearDown(() {
    configDir.deleteSync(recursive: true);
    projectA.deleteSync(recursive: true);
    projectB.deleteSync(recursive: true);
  });

  test('open() records a project and returns its normalized path', () async {
    final manager = ProjectManager(configDir: configDir.path);
    final opened = await manager.open(projectA.path);
    expect(opened, p.normalize(projectA.path));

    final recent = await manager.listRecent();
    expect(recent, hasLength(1));
    expect(recent.first.path, opened);
  });

  test('open() on a missing directory throws ProjectNotFoundException', () async {
    final manager = ProjectManager(configDir: configDir.path);
    expect(
      () => manager.open(p.join(projectA.path, 'does-not-exist')),
      throwsA(isA<ProjectNotFoundException>()),
    );
  });

  test('re-opening a project moves it to the front and does not duplicate it', () async {
    final manager = ProjectManager(configDir: configDir.path);
    await manager.open(projectA.path);
    await manager.open(projectB.path);
    await manager.open(projectA.path);

    final recent = await manager.listRecent();
    expect(recent, hasLength(2));
    expect(recent.first.path, p.normalize(projectA.path));
  });

  test('a second ProjectManager instance on the same config dir sees prior state', () async {
    final first = ProjectManager(configDir: configDir.path);
    await first.open(projectA.path);

    final second = ProjectManager(configDir: configDir.path);
    final recent = await second.listRecent();
    expect(recent, hasLength(1));
  });

  test('forget() removes a project from the recent list', () async {
    final manager = ProjectManager(configDir: configDir.path);
    await manager.open(projectA.path);
    await manager.forget(projectA.path);
    expect(await manager.listRecent(), isEmpty);
  });
}
