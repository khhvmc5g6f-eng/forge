import '../agents/agent_role.dart';
import '../models/task_classifier.dart';
import '../tools/tool_category.dart';
import 'model_tier.dart';

/// The structured contract every delegated task receives, per the spec:
/// "TASK ID, OBJECTIVE, SCOPE, ALLOWED FILES, RELEVANT CONTEXT, TOOLS,
/// PERMISSIONS, EXPECTED OUTPUT, TEST REQUIREMENTS, TOKEN BUDGET, TIME
/// BUDGET, MODEL, RETURN FORMAT." Workers receive only this — never the
/// supervisor's full context — per "Workers should receive only the context
/// required for their assignment."
class TaskContract {
  const TaskContract({
    required this.id,
    required this.objective,
    required this.scope,
    this.allowedFiles = const [],
    this.relevantContext = '',
    this.tools = const {},
    this.permissions = PermissionLevel.proposeEdits,
    this.expectedOutput = '',
    this.testRequirements = const [],
    this.tokenBudget = 50000,
    this.timeBudget = const Duration(minutes: 10),
    required this.tier,
    required this.taskCategory,
    this.role = AgentRole.coding,
    this.returnFormat = 'RESULT / EVIDENCE / CONFIDENCE / UNCERTAINTIES / NEXT ACTION',
  });

  final String id;
  final String objective;
  final String scope;
  final List<String> allowedFiles;
  final String relevantContext;
  final Set<ToolCategory> tools;
  final PermissionLevel permissions;
  final String expectedOutput;
  final List<String> testRequirements;
  final int tokenBudget;
  final Duration timeBudget;
  final ModelTier tier;
  final TaskCategory taskCategory;

  /// Which specialist role (and therefore which [AgentDefinition] — system
  /// prompt, allowed tool categories) executes this node. Defaults to
  /// [AgentRole.coding]; the Supervisor sets this explicitly per node (e.g.
  /// [AgentRole.repository] for a log/history investigation,
  /// [AgentRole.testing] for a test-writing node).
  final AgentRole role;
  final String returnFormat;

  /// Renders the contract as the prompt a worker actually receives.
  /// [priorAttemptNote] carries a short handover note when this is a retry
  /// after a failed/failed-over attempt — see `SupervisorEngine`.
  String render({String? priorAttemptNote}) {
    final buffer = StringBuffer()
      ..writeln('TASK $id')
      ..writeln('OBJECTIVE: $objective')
      ..writeln('SCOPE: $scope')
      ..writeln(
          'ALLOWED FILES: ${allowedFiles.isEmpty ? '(unrestricted within project sandbox)' : allowedFiles.join(', ')}')
      ..writeln('EXPECTED OUTPUT: ${expectedOutput.isEmpty ? '(see return format)' : expectedOutput}')
      ..writeln('TEST REQUIREMENTS: ${testRequirements.isEmpty ? '(none specified)' : testRequirements.join(', ')}')
      ..writeln('RETURN FORMAT: $returnFormat');
    if (relevantContext.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('RELEVANT CONTEXT:')
        ..writeln(relevantContext);
    }
    if (priorAttemptNote != null) {
      buffer
        ..writeln()
        ..writeln('PRIOR ATTEMPT NOTE (this is a retry — do not repeat the same failed approach):')
        ..writeln(priorAttemptNote);
    }
    return buffer.toString();
  }
}

enum GraphNodeStatus { pending, running, paused, done, failed, cancelled }

/// A worker's structured response, per the spec: "Workers return: RESULT,
/// EVIDENCE, CONFIDENCE, UNCERTAINTIES, RECOMMENDED NEXT ACTION."
class WorkerResult {
  const WorkerResult({
    required this.resultText,
    required this.evidence,
    required this.confidence,
    this.uncertainties = const [],
    this.recommendedNextAction = '',
    this.rawResponse = '',
  });

  final String resultText;
  final String evidence;

  /// 0.0–1.0. Below [SupervisorEngine.lowConfidenceThreshold] triggers
  /// automatic escalation per the spec: "Low confidence automatically
  /// triggers: second worker, senior review, or supervisor escalation."
  final double confidence;
  final List<String> uncertainties;
  final String recommendedNextAction;
  final String rawResponse;

  /// Parses a worker's free-text response into a [WorkerResult]. Looks for
  /// labelled lines (`RESULT:`, `EVIDENCE:`, `CONFIDENCE:`,
  /// `UNCERTAINTIES:`, `NEXT ACTION:`); anything not found defaults to an
  /// empty/neutral value rather than throwing — a worker that ignores the
  /// requested format still returns *something* usable, just with
  /// [confidence] defaulting low enough to trigger escalation.
  factory WorkerResult.parse(String response) {
    String section(String label) {
      final pattern = RegExp('$label:\\s*(.*)', caseSensitive: false);
      final match = pattern.firstMatch(response);
      return match?.group(1)?.trim() ?? '';
    }

    final confidenceText = section('CONFIDENCE');
    final confidenceMatch = RegExp(r'(\d+(\.\d+)?)').firstMatch(confidenceText);
    var confidence = 0.4; // neutral-low default when unparsable, not a silent high-confidence pass
    if (confidenceMatch != null) {
      var value = double.parse(confidenceMatch.group(1)!);
      if (value > 1) value /= 100; // tolerate "90" meaning 90%
      confidence = value.clamp(0.0, 1.0);
    }

    final uncertaintiesText = section('UNCERTAINTIES');
    final uncertainties = uncertaintiesText.isEmpty
        ? <String>[]
        : uncertaintiesText.split(RegExp(r'[;,]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

    return WorkerResult(
      resultText: section('RESULT').isEmpty ? response.trim() : section('RESULT'),
      evidence: section('EVIDENCE'),
      confidence: confidence,
      uncertainties: uncertainties,
      recommendedNextAction: section('NEXT ACTION'),
      rawResponse: response,
    );
  }
}

/// One node in the [TaskGraph] — one delegated [TaskContract] plus its
/// dependency edges and live status. The Supervisor's view of "master task,
/// task graph, worker assignments, dependencies, status, results,
/// confidence" all lives here.
class TaskGraphNode {
  TaskGraphNode({required this.contract, this.dependsOn = const []});

  final TaskContract contract;
  final List<String> dependsOn;

  GraphNodeStatus status = GraphNodeStatus.pending;
  WorkerResult? result;
  int attempts = 0;
  final List<String> modelsAttempted = [];
  String? assignedModelKey;
  String? failureReason;

  bool get isReady => status == GraphNodeStatus.pending;
}

/// The full task graph for one master objective. Dependency-aware:
/// [readyNodes] only returns nodes whose dependencies are all `done`, so
/// independent branches (logs / Git / tests in the spec's worked example)
/// can be dispatched in parallel while dependent work waits.
class TaskGraph {
  TaskGraph({required this.masterObjective, this.maxTokenBudget = 500000, this.deadline});

  final String masterObjective;
  final int maxTokenBudget;
  final DateTime? deadline;
  final Map<String, TaskGraphNode> nodes = {};
  final List<String> conflicts = [];
  int tokensUsed = 0;

  void addNode(TaskGraphNode node) => nodes[node.contract.id] = node;

  List<TaskGraphNode> get readyNodes => nodes.values
      .where((n) =>
          n.status == GraphNodeStatus.pending &&
          n.dependsOn.every((depId) => nodes[depId]?.status == GraphNodeStatus.done))
      .toList();

  bool get isComplete =>
      nodes.values.every((n) => n.status == GraphNodeStatus.done || n.status == GraphNodeStatus.cancelled);

  bool get hasUnrecoverableFailure => nodes.values.any((n) => n.status == GraphNodeStatus.failed);

  bool get budgetExhausted => tokensUsed >= maxTokenBudget;

  List<TaskGraphNode> get allNodes => nodes.values.toList(growable: false);

  // Supervisor controls, per the spec: "pause worker, cancel worker,
  // reassign task, escalate task."
  void pause(String nodeId) {
    final node = nodes[nodeId];
    if (node != null && node.status == GraphNodeStatus.running) node.status = GraphNodeStatus.paused;
  }

  void resume(String nodeId) {
    final node = nodes[nodeId];
    if (node != null && node.status == GraphNodeStatus.paused) node.status = GraphNodeStatus.pending;
  }

  void cancel(String nodeId) {
    final node = nodes[nodeId];
    if (node != null &&
        node.status != GraphNodeStatus.done &&
        node.status != GraphNodeStatus.cancelled) {
      node.status = GraphNodeStatus.cancelled;
    }
  }
}
