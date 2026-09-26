import '../security/untrusted_content.dart';
import 'policy_engine.dart';
import 'tool_category.dart';

/// A single executable capability the agent runtime can invoke. Every tool
/// — filesystem, terminal, git, MCP-provided, browser, device — implements
/// this same interface so the [ToolGateway] can apply one uniform
/// policy-check-then-execute pipeline regardless of category.
abstract class Tool {
  String get name;
  ToolCategory get category;
  String get description;

  /// JSON-Schema parameters, surfaced to the model via [ToolSpec].
  Map<String, dynamic> get parametersSchema;

  /// Builds the [ToolInvocation] the [PolicyEngine] will judge, from the
  /// model-supplied arguments. Must not perform any side effects.
  ToolInvocation describeInvocation(Map<String, dynamic> arguments);

  /// Performs the action. Only called by [ToolGateway] after
  /// [PolicyEngine.decide] has returned [PermissionDecision.allow] (or the
  /// user has approved an `ask`). Implementations must not re-check policy.
  Future<UntrustedContent> execute(Map<String, dynamic> arguments);
}

typedef ApprovalPrompt = Future<bool> Function(ToolInvocation invocation, String reason);

class ToolExecutionRecord {
  ToolExecutionRecord({
    required this.toolName,
    required this.invocation,
    required this.decision,
    required this.startedAt,
    this.finishedAt,
    this.result,
    this.error,
  });

  final String toolName;
  final ToolInvocation invocation;
  final PolicyDecisionResult decision;
  final DateTime startedAt;
  DateTime? finishedAt;
  UntrustedContent? result;
  Object? error;

  bool get succeeded => error == null && result != null;
}

class ToolDeniedException implements Exception {
  ToolDeniedException(this.invocation, this.reason);
  final ToolInvocation invocation;
  final String reason;

  @override
  String toString() => 'Tool denied: ${invocation.toolName} — $reason';
}

/// The single entry point every agent goes through to touch the filesystem,
/// a shell, Git, a device, or an MCP server. Wraps [PolicyEngine] +
/// tool execution + an audit trail ([ToolExecutionRecord]s), and is the
/// concrete implementation of the brief's
/// `MODEL -> TOOL REQUEST -> POLICY ENGINE -> PERMISSION -> EXECUTOR -> RESULT -> MODEL`
/// pipeline.
class ToolGateway {
  ToolGateway({required this.policyEngine, this.onApprovalNeeded});

  final PolicyEngine policyEngine;

  /// Invoked when the Policy Engine returns [PermissionDecision.ask]. Wired
  /// to a UI confirmation dialog in the desktop shell, and to a CLI y/n
  /// prompt in `aiwork`/`forge`. If null, `ask` decisions are treated as
  /// denied (fail closed rather than silently proceeding).
  final ApprovalPrompt? onApprovalNeeded;

  final Map<String, Tool> _tools = {};
  final List<ToolExecutionRecord> auditLog = [];

  void register(Tool tool) => _tools[tool.name] = tool;

  List<Tool> get registeredTools => _tools.values.toList(growable: false);

  Future<UntrustedContent> invoke(String toolName, Map<String, dynamic> arguments) async {
    final tool = _tools[toolName];
    if (tool == null) {
      throw ArgumentError('Unknown tool: $toolName');
    }
    final invocation = tool.describeInvocation(arguments);
    final decision = policyEngine.decide(invocation);
    final record = ToolExecutionRecord(
      toolName: toolName,
      invocation: invocation,
      decision: decision,
      startedAt: DateTime.now(),
    );
    auditLog.add(record);

    var effectiveDecision = decision.decision;
    if (effectiveDecision == PermissionDecision.ask) {
      final approved = onApprovalNeeded == null
          ? false
          : await onApprovalNeeded!(invocation, decision.reason);
      effectiveDecision =
          approved ? PermissionDecision.allow : PermissionDecision.deny;
    }

    if (effectiveDecision == PermissionDecision.deny) {
      final exception = ToolDeniedException(invocation, decision.reason);
      record
        ..error = exception
        ..finishedAt = DateTime.now();
      throw exception;
    }

    try {
      final result = await tool.execute(arguments);
      record
        ..result = result
        ..finishedAt = DateTime.now();
      return result;
    } catch (e) {
      record
        ..error = e
        ..finishedAt = DateTime.now();
      rethrow;
    }
  }
}
