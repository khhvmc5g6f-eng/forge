import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/tools/policy_engine.dart';
import 'package:forge/core/tools/tool_category.dart';

void main() {
  group('PolicyEngine', () {
    test('allows a safe read within the sandbox at observe level', () {
      final engine = PolicyEngine(
        mode: OperatingMode.chat,
        grantedLevel: PermissionLevel.observe,
        projectRoot: '/home/user/project',
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.filesystem,
        toolName: 'read_file',
        targetPath: '/home/user/project/lib/main.dart',
        explicitLevel: PermissionLevel.observe,
      ));
      expect(result.decision, PermissionDecision.allow);
    });

    test('denies any path outside the sandbox regardless of level', () {
      final engine = PolicyEngine(
        mode: OperatingMode.autonomous,
        grantedLevel: PermissionLevel.productionActions,
        projectRoot: '/home/user/project',
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.filesystem,
        toolName: 'read_file',
        targetPath: '/home/user/.ssh/id_rsa',
      ));
      expect(result.decision, PermissionDecision.deny);
    });

    test('destructive commands always ask, even at max permission/autonomous mode', () {
      final engine = PolicyEngine(
        mode: OperatingMode.autonomous,
        grantedLevel: PermissionLevel.productionActions,
        projectRoot: '/repo',
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.terminal,
        toolName: 'run_terminal_command',
        commandRisk: CommandRisk.destructive,
        targetPath: '/repo',
      ));
      expect(result.decision, PermissionDecision.ask);
    });

    test('privileged commands always ask, never silently allowed', () {
      final engine = PolicyEngine(
        mode: OperatingMode.autonomous,
        grantedLevel: PermissionLevel.productionActions,
        projectRoot: '/repo',
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.terminal,
        toolName: 'run_terminal_command',
        commandRisk: CommandRisk.privileged,
        targetPath: '/repo',
      ));
      expect(result.decision, PermissionDecision.ask);
    });

    test('chat mode denies build even if permission level would allow it', () {
      final engine = PolicyEngine(
        mode: OperatingMode.chat,
        grantedLevel: PermissionLevel.productionActions,
        projectRoot: '/repo',
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.terminal,
        toolName: 'run_terminal_command',
        commandRisk: CommandRisk.build,
        targetPath: '/repo',
      ));
      expect(result.decision, PermissionDecision.deny);
    });

    test('agent mode asks for build when granted level is too low', () {
      final engine = PolicyEngine(
        mode: OperatingMode.agent,
        grantedLevel: PermissionLevel.observe,
        projectRoot: '/repo',
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.terminal,
        toolName: 'run_terminal_command',
        commandRisk: CommandRisk.build,
        targetPath: '/repo',
      ));
      expect(result.decision, PermissionDecision.ask);
    });

    test('agent mode allows build when granted level is sufficient', () {
      final engine = PolicyEngine(
        mode: OperatingMode.agent,
        grantedLevel: PermissionLevel.runBuildTest,
        projectRoot: '/repo',
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.terminal,
        toolName: 'run_terminal_command',
        commandRisk: CommandRisk.build,
        targetPath: '/repo',
      ));
      expect(result.decision, PermissionDecision.allow);
    });

    test('workspace roots outside the project root are still allowed when listed', () {
      final engine = PolicyEngine(
        mode: OperatingMode.agent,
        grantedLevel: PermissionLevel.editProject,
        projectRoot: '/repo',
        allowedWorkspaceRoots: const ['/tmp/forge-workspace'],
      );
      final result = engine.decide(const ToolInvocation(
        category: ToolCategory.filesystem,
        toolName: 'create_file',
        targetPath: '/tmp/forge-workspace/scratch.txt',
        explicitLevel: PermissionLevel.editProject,
      ));
      expect(result.decision, PermissionDecision.allow);
    });
  });
}
