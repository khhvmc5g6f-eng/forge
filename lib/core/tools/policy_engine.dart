import 'package:path/path.dart' as p;

import 'tool_category.dart';

enum PermissionDecision { allow, ask, deny }

class PolicyDecisionResult {
  const PolicyDecisionResult(this.decision, this.reason);
  final PermissionDecision decision;
  final String reason;
}

/// A single, structured request to perform a tool action. The model never
/// hands the Policy Engine free text — it hands it one of these, built by
/// the Tool Gateway from the model's tool call plus context the model
/// cannot forge (current mode, current permission level, project root).
class ToolInvocation {
  const ToolInvocation({
    required this.category,
    required this.toolName,
    this.commandRisk,
    this.targetPath,
    this.description = '',
    this.explicitLevel,
  });

  final ToolCategory category;
  final String toolName;

  /// Only set for [ToolCategory.terminal] invocations, from
  /// [CommandClassifier].
  final CommandRisk? commandRisk;

  /// Absolute path the action targets, when applicable (filesystem/git
  /// tools). Used to enforce the project-root sandbox boundary.
  final String? targetPath;

  final String description;

  /// Lets a tool state its own required [PermissionLevel] directly instead
  /// of relying on [PolicyEngine]'s per-category default — used where a
  /// category is too coarse (e.g. read-only `git_status` vs. mutating
  /// `git_commit`, both [ToolCategory.git]).
  final PermissionLevel? explicitLevel;
}

/// Static per-[CommandRisk] permission requirement. Non-terminal tool
/// categories map their own minimum level in [PolicyEngine._levelFor].
const Map<CommandRisk, PermissionLevel> _riskLevel = {
  CommandRisk.safe: PermissionLevel.observe,
  CommandRisk.read: PermissionLevel.observe,
  CommandRisk.network: PermissionLevel.diagnose,
  CommandRisk.install: PermissionLevel.runBuildTest,
  CommandRisk.build: PermissionLevel.runBuildTest,
  CommandRisk.test: PermissionLevel.runBuildTest,
  CommandRisk.modify: PermissionLevel.editProject,
  // destructive/privileged are handled specially — see decide().
  CommandRisk.destructive: PermissionLevel.productionActions,
  CommandRisk.privileged: PermissionLevel.productionActions,
};

/// The deterministic authority for every tool action in Forge. The brief is
/// explicit that "the deterministic Policy Engine, not the LLM, controls
/// permissions" — this class is that control point, and it is the *only*
/// class in Forge allowed to produce a [PermissionDecision]. It takes no
/// model output as input, only structured, code-constructed values.
class PolicyEngine {
  PolicyEngine({
    required this.mode,
    required this.grantedLevel,
    required this.projectRoot,
    this.allowedWorkspaceRoots = const [],
  });

  OperatingMode mode;
  PermissionLevel grantedLevel;

  /// The project's own root — the primary sandbox boundary. A filesystem or
  /// git tool targeting a path outside this (and outside
  /// [allowedWorkspaceRoots], e.g. a scratch/temp workspace) is always
  /// denied, regardless of mode or permission level: no permission level
  /// grants access to "the rest of the Mac".
  final String projectRoot;
  final List<String> allowedWorkspaceRoots;

  PolicyDecisionResult decide(ToolInvocation invocation) {
    if (invocation.targetPath != null && !_withinSandbox(invocation.targetPath!)) {
      return const PolicyDecisionResult(
        PermissionDecision.deny,
        'Target path is outside the authorised project/workspace sandbox.',
      );
    }

    final risk = invocation.commandRisk;
    if (risk == CommandRisk.destructive || risk == CommandRisk.privileged) {
      // Per SECURITY.md: destructive/privileged actions always require an
      // explicit human confirmation, in every mode, at every permission
      // level. Autonomy raises convenience, never raises the security
      // ceiling.
      return PolicyDecisionResult(
        PermissionDecision.ask,
        '${risk!.name} commands always require explicit confirmation.',
      );
    }

    final requiredLevel = _levelFor(invocation);
    final modeCap = maxPermissionForMode[mode]!;

    if (modeCap.rank < requiredLevel.rank) {
      return PolicyDecisionResult(
        PermissionDecision.deny,
        '${mode.name} mode does not permit ${invocation.category.name} '
        'actions requiring ${requiredLevel.name}.',
      );
    }

    if (grantedLevel.rank >= requiredLevel.rank) {
      return PolicyDecisionResult(
        PermissionDecision.allow,
        'Granted permission level ${grantedLevel.name} covers '
        '${requiredLevel.name}.',
      );
    }

    return PolicyDecisionResult(
      PermissionDecision.ask,
      'Requires ${requiredLevel.name}; current granted level is '
      '${grantedLevel.name}.',
    );
  }

  PermissionLevel _levelFor(ToolInvocation invocation) {
    if (invocation.explicitLevel != null) return invocation.explicitLevel!;
    if (invocation.category == ToolCategory.terminal && invocation.commandRisk != null) {
      return _riskLevel[invocation.commandRisk]!;
    }
    switch (invocation.category) {
      case ToolCategory.filesystem:
        return PermissionLevel.editProject;
      case ToolCategory.git:
        return PermissionLevel.commitToAiBranch;
      case ToolCategory.github:
        return PermissionLevel.pushOrCreatePr;
      case ToolCategory.build:
      case ToolCategory.test:
      case ToolCategory.device:
        return PermissionLevel.runBuildTest;
      case ToolCategory.browser:
      case ToolCategory.computer:
        return PermissionLevel.controlTestDevice;
      case ToolCategory.database:
      case ToolCategory.network:
      case ToolCategory.mcp:
        return PermissionLevel.diagnose;
      case ToolCategory.terminal:
        return PermissionLevel.observe;
    }
  }

  bool _withinSandbox(String path) {
    final normalizedTarget = p.normalize(path);
    final roots = [projectRoot, ...allowedWorkspaceRoots].map(p.normalize);
    return roots.any((root) =>
        normalizedTarget == root || p.isWithin(root, normalizedTarget));
  }
}
