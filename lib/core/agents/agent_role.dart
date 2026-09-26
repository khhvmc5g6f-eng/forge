import '../models/task_classifier.dart';
import '../tools/tool_category.dart';

/// Every specialist agent named in the brief. These are *roles*, not
/// classes — a single [AgentRuntime] executes whichever [AgentDefinition]
/// the Orchestrator assigns it, so adding a new role is a configuration
/// change, not new agent code.
enum AgentRole {
  orchestrator,
  planning,
  repository,
  coding,
  debugging,
  architecture,
  testing,
  performance,
  security,
  database,
  api,
  ui,
  browser,
  computerUse,
  git,
  documentation,
  dependency,
  review,
  finalReviewPreparation,
}

/// Declarative configuration for one [AgentRole]: its system prompt, the
/// tool categories it may call (further narrowed by [PolicyEngine] at
/// invocation time — this is a hint for tool-list scoping, not a security
/// boundary), and which [TaskCategory] the Model Router should assume when
/// picking a model for it.
class AgentDefinition {
  const AgentDefinition({
    required this.role,
    required this.systemPrompt,
    required this.allowedToolCategories,
    required this.defaultTaskCategory,
    this.maxIterations = 25,
  });

  final AgentRole role;
  final String systemPrompt;
  final Set<ToolCategory> allowedToolCategories;
  final TaskCategory defaultTaskCategory;
  final int maxIterations;
}

/// The built-in role catalogue. A user or plugin may register additional
/// [AgentDefinition]s at runtime (see PLUGINS in ARCHITECTURE.md); this map
/// is the default set shipped with Forge.
final Map<AgentRole, AgentDefinition> defaultAgentDefinitions = {
  AgentRole.orchestrator: const AgentDefinition(
    role: AgentRole.orchestrator,
    systemPrompt:
        'You are the Orchestrator. Break the user\'s request into a plan, '
        'delegate bounded investigations to specialist subagents, and '
        'synthesise their findings. You do not edit files yourself.',
    allowedToolCategories: {},
    defaultTaskCategory: TaskCategory.architecture,
  ),
  AgentRole.planning: const AgentDefinition(
    role: AgentRole.planning,
    systemPrompt:
        'You are the Planning Agent. Produce a concrete, checkable step list '
        'for the given task using the repository context provided.',
    allowedToolCategories: {ToolCategory.filesystem},
    defaultTaskCategory: TaskCategory.architecture,
  ),
  AgentRole.repository: const AgentDefinition(
    role: AgentRole.repository,
    systemPrompt:
        'You are the Repository Agent. Locate the files, symbols, and '
        'history relevant to the task using search tools; report findings, '
        'do not modify anything.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.git},
    defaultTaskCategory: TaskCategory.repositoryResearch,
  ),
  AgentRole.coding: const AgentDefinition(
    role: AgentRole.coding,
    systemPrompt:
        'You are the Coding Agent. Implement the requested change using '
        'patch_file/create_file. Keep changes minimal and scoped to the '
        'task.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.terminal},
    defaultTaskCategory: TaskCategory.complexCode,
  ),
  AgentRole.debugging: const AgentDefinition(
    role: AgentRole.debugging,
    systemPrompt:
        'You are the Debugging Agent. Reproduce the failure, inspect logs '
        'and state, and identify the root cause before proposing a fix.',
    allowedToolCategories: {
      ToolCategory.filesystem,
      ToolCategory.terminal,
      ToolCategory.device,
    },
    defaultTaskCategory: TaskCategory.debugging,
  ),
  AgentRole.architecture: const AgentDefinition(
    role: AgentRole.architecture,
    systemPrompt:
        'You are the Architecture Agent. Evaluate structural trade-offs and '
        'recommend an approach; you do not write implementation code.',
    allowedToolCategories: {ToolCategory.filesystem},
    defaultTaskCategory: TaskCategory.architecture,
  ),
  AgentRole.testing: const AgentDefinition(
    role: AgentRole.testing,
    systemPrompt:
        'You are the Testing Agent. Run the project\'s test suite, report '
        'failures precisely, and write new tests when asked.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.terminal, ToolCategory.test},
    defaultTaskCategory: TaskCategory.testing,
  ),
  AgentRole.performance: const AgentDefinition(
    role: AgentRole.performance,
    systemPrompt:
        'You are the Performance Agent. Profile CPU/memory/frame-time '
        'behaviour and identify the specific hot path causing the issue.',
    allowedToolCategories: {ToolCategory.terminal, ToolCategory.device},
    defaultTaskCategory: TaskCategory.debugging,
  ),
  AgentRole.security: const AgentDefinition(
    role: AgentRole.security,
    systemPrompt:
        'You are the Security Agent. Review the diff for injection, auth, '
        'secrets-handling, and privilege issues.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.git},
    defaultTaskCategory: TaskCategory.review,
  ),
  AgentRole.database: const AgentDefinition(
    role: AgentRole.database,
    systemPrompt: 'You are the Database Agent. Review schema/query changes and migrations.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.database},
    defaultTaskCategory: TaskCategory.complexCode,
  ),
  AgentRole.api: const AgentDefinition(
    role: AgentRole.api,
    systemPrompt: 'You are the API Agent. Review/implement API contracts and integrations.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.network},
    defaultTaskCategory: TaskCategory.complexCode,
  ),
  AgentRole.ui: const AgentDefinition(
    role: AgentRole.ui,
    systemPrompt: 'You are the UI Agent. Implement/adjust interface code.',
    allowedToolCategories: {ToolCategory.filesystem},
    defaultTaskCategory: TaskCategory.complexCode,
  ),
  AgentRole.browser: const AgentDefinition(
    role: AgentRole.browser,
    systemPrompt: 'You are the Browser Agent. Drive the configured browser automation tools to test web behaviour.',
    allowedToolCategories: {ToolCategory.browser},
    defaultTaskCategory: TaskCategory.testing,
  ),
  AgentRole.computerUse: const AgentDefinition(
    role: AgentRole.computerUse,
    systemPrompt:
        'You are the Computer-Use Agent. Prefer semantic/accessibility '
        'control over coordinate-based clicking; screen control must be '
        'visibly indicated and immediately stoppable.',
    allowedToolCategories: {ToolCategory.computer},
    defaultTaskCategory: TaskCategory.testing,
  ),
  AgentRole.git: const AgentDefinition(
    role: AgentRole.git,
    systemPrompt: 'You are the Git Agent. Manage branches, commits, and checkpoints for the task.',
    allowedToolCategories: {ToolCategory.git, ToolCategory.github},
    defaultTaskCategory: TaskCategory.simpleCode,
  ),
  AgentRole.documentation: const AgentDefinition(
    role: AgentRole.documentation,
    systemPrompt: 'You are the Documentation Agent. Keep docs consistent with the shipped change.',
    allowedToolCategories: {ToolCategory.filesystem},
    defaultTaskCategory: TaskCategory.simpleCode,
  ),
  AgentRole.dependency: const AgentDefinition(
    role: AgentRole.dependency,
    systemPrompt: 'You are the Dependency Agent. Evaluate and manage package dependencies.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.terminal},
    defaultTaskCategory: TaskCategory.repositoryResearch,
  ),
  AgentRole.review: const AgentDefinition(
    role: AgentRole.review,
    systemPrompt:
        'You are an Independent Review Agent. You did not author this '
        'patch. Identify logic errors, regressions, missing tests, and '
        'unnecessary complexity. Return PASS, PASS WITH CONCERNS, REWORK, '
        'or FAIL with evidence.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.git},
    defaultTaskCategory: TaskCategory.review,
  ),
  AgentRole.finalReviewPreparation: const AgentDefinition(
    role: AgentRole.finalReviewPreparation,
    systemPrompt:
        'You are the Final Review Preparation Agent. Compress the task '
        'history into a compact Review Package for the final reviewer: '
        'task, requirements, diff, files changed, tests, build results, '
        'known limitations — never the full development transcript.',
    allowedToolCategories: {ToolCategory.filesystem, ToolCategory.git},
    defaultTaskCategory: TaskCategory.review,
  ),
};
