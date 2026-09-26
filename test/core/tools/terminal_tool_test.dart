import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/tools/policy_engine.dart';
import 'package:forge/core/tools/terminal_tool.dart';
import 'package:forge/core/tools/tool.dart';
import 'package:forge/core/tools/tool_category.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('forge_terminal_test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('executes a benign command and records its output', () async {
    final tool = TerminalTool(workingDirectory: tempDir.path, agentId: 'test');
    final result = await tool.execute({'command': 'echo hello'});
    expect(result.body, contains('exit_code: 0'));
    expect(result.body, contains('hello'));
  });

  test('policy engine deny blocks execution even without the gateway', () async {
    // chat mode caps permissions below what a modify-level command needs.
    final policy = PolicyEngine(
      mode: OperatingMode.chat,
      grantedLevel: PermissionLevel.observe,
      projectRoot: tempDir.path,
    );
    final tool = TerminalTool(
      workingDirectory: tempDir.path,
      agentId: 'test',
      policyEngine: policy,
    );
    expect(
      () => tool.execute({'command': 'touch inside.txt'}),
      throwsA(isA<ToolDeniedException>()),
    );
    // Fail-closed: nothing was executed at all.
    expect(tool.history, isEmpty);
  });

  test('seatbelt-wrapped commands cannot write outside the working directory',
      () async {
    final outside =
        Directory.systemTemp.createTempSync('forge_terminal_outside');
    try {
      final tool = TerminalTool(
        workingDirectory: tempDir.path,
        agentId: 'test',
        useSeatbelt: true,
      );
      final result = await tool.execute({
        'command': 'echo x > "${outside.path}/escape.txt"',
      });
      // Either the sandbox denied the write (non-zero exit, error in
      // stderr) — but the file must not exist outside the project root.
      expect(File('${outside.path}/escape.txt').existsSync(), isFalse,
          reason: 'seatbelt must block writes outside the project root; '
              'tool output was: ${result.body}');
    } finally {
      await outside.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS ? 'seatbelt is macOS-only' : null);

  test('history records every execution', () async {
    final tool = TerminalTool(workingDirectory: tempDir.path, agentId: 'test');
    await tool.execute({'command': 'echo hi'});
    expect(tool.history, hasLength(1));
    expect(tool.history.first.exitCode, 0);
    expect(tool.history.first.risk, CommandRisk.safe);
  });
}
