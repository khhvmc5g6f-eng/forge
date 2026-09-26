/// The repair-loop steps from the brief's
/// `OBSERVE -> DETECT -> REPRODUCE -> DIAGNOSE -> PATCH -> ANALYSE -> TEST ->
/// BUILD -> RUN -> VERIFY -> REGRESSION TEST -> REVIEW` diagram, plus the
/// simpler PLAN/INSPECT/EDIT steps for non-debugging tasks. A [Task] tracks
/// a checklist of these so progress is always visible and resumable.
enum TaskStepKind {
  plan,
  inspectRepository,
  observe,
  detect,
  reproduce,
  diagnose,
  edit,
  patch,
  analyse,
  runTerminal,
  build,
  test,
  verify,
  regressionTest,
  independentReview,
  finalReview,
  userApproval,
  commitOrPr,
}

enum StepStatus { pending, inProgress, done, failed, skipped }

class TaskStepRecord {
  TaskStepRecord({required this.kind, this.status = StepStatus.pending, this.note = ''});

  final TaskStepKind kind;
  StepStatus status;
  String note;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'status': status.name,
        'note': note,
      };

  factory TaskStepRecord.fromJson(Map<String, dynamic> json) => TaskStepRecord(
        kind: TaskStepKind.values.byName(json['kind'] as String),
        status: StepStatus.values.byName(json['status'] as String),
        note: json['note'] as String? ?? '',
      );
}

enum TaskStatus { pending, running, blocked, completed, failed, cancelled }

/// A single substantial unit of work, per the brief: "Every substantial
/// request becomes a Task." Persisted to disk so a restarted application can
/// offer "RESUME TASK" with full knowledge of what was already done.
class Task {
  Task({
    required this.id,
    required this.title,
    required this.description,
    required this.createdAt,
    List<TaskStepRecord>? steps,
    this.status = TaskStatus.pending,
    this.updatedAt,
    this.branch,
    List<String>? checkpointIds,
    List<String>? involvedAgentIds,
    List<String>? modelIdsUsed,
    this.repairIterationCount = 0,
    this.maxRepairIterations = 6,
    this.reviewCycleCount = 0,
    this.maxReviewCycles = 3,
  })  : steps = steps ?? [],
        checkpointIds = checkpointIds ?? [],
        involvedAgentIds = involvedAgentIds ?? [],
        modelIdsUsed = modelIdsUsed ?? [];

  final String id;
  final String title;
  final String description;
  final DateTime createdAt;
  DateTime? updatedAt;

  TaskStatus status;
  final List<TaskStepRecord> steps;
  String? branch;
  final List<String> checkpointIds;
  final List<String> involvedAgentIds;
  final List<String> modelIdsUsed;

  /// Guards against the brief's "Do not allow infinite repair loops" — once
  /// exceeded, the task moves to [TaskStatus.blocked] pending human input
  /// rather than continuing to retry.
  int repairIterationCount;
  final int maxRepairIterations;

  /// Guards the Worker <-> Reviewer rework cycle's "configurable maximum
  /// review cycle".
  int reviewCycleCount;
  final int maxReviewCycles;

  bool get repairBudgetExhausted => repairIterationCount >= maxRepairIterations;
  bool get reviewBudgetExhausted => reviewCycleCount >= maxReviewCycles;

  TaskStepRecord? get currentStep =>
      steps.where((s) => s.status == StepStatus.inProgress).firstOrNull ??
      steps.where((s) => s.status == StepStatus.pending).firstOrNull;

  TaskStepRecord? get lastCompletedStep {
    TaskStepRecord? last;
    for (final step in steps) {
      if (step.status == StepStatus.done) last = step;
    }
    return last;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
        'status': status.name,
        'steps': steps.map((s) => s.toJson()).toList(),
        'branch': branch,
        'checkpointIds': checkpointIds,
        'involvedAgentIds': involvedAgentIds,
        'modelIdsUsed': modelIdsUsed,
        'repairIterationCount': repairIterationCount,
        'maxRepairIterations': maxRepairIterations,
        'reviewCycleCount': reviewCycleCount,
        'maxReviewCycles': maxReviewCycles,
      };

  factory Task.fromJson(Map<String, dynamic> json) => Task(
        id: json['id'] as String,
        title: json['title'] as String,
        description: json['description'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: json['updatedAt'] == null ? null : DateTime.parse(json['updatedAt'] as String),
        status: TaskStatus.values.byName(json['status'] as String),
        steps: (json['steps'] as List)
            .map((s) => TaskStepRecord.fromJson(s as Map<String, dynamic>))
            .toList(),
        branch: json['branch'] as String?,
        checkpointIds: (json['checkpointIds'] as List).cast<String>(),
        involvedAgentIds: (json['involvedAgentIds'] as List).cast<String>(),
        modelIdsUsed: (json['modelIdsUsed'] as List).cast<String>(),
        repairIterationCount: json['repairIterationCount'] as int? ?? 0,
        maxRepairIterations: json['maxRepairIterations'] as int? ?? 6,
        reviewCycleCount: json['reviewCycleCount'] as int? ?? 0,
        maxReviewCycles: json['maxReviewCycles'] as int? ?? 3,
      );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// The default step checklist for a general coding task, matching the
/// brief's TASK #8472 example (inspect logs, reproduce, locate source,
/// patch, test, independent review).
List<TaskStepRecord> defaultDebugWorkflowSteps() => [
      TaskStepRecord(kind: TaskStepKind.plan),
      TaskStepRecord(kind: TaskStepKind.inspectRepository),
      TaskStepRecord(kind: TaskStepKind.observe),
      TaskStepRecord(kind: TaskStepKind.reproduce),
      TaskStepRecord(kind: TaskStepKind.diagnose),
      TaskStepRecord(kind: TaskStepKind.patch),
      TaskStepRecord(kind: TaskStepKind.build),
      TaskStepRecord(kind: TaskStepKind.test),
      TaskStepRecord(kind: TaskStepKind.verify),
      TaskStepRecord(kind: TaskStepKind.regressionTest),
      TaskStepRecord(kind: TaskStepKind.independentReview),
      TaskStepRecord(kind: TaskStepKind.finalReview),
      TaskStepRecord(kind: TaskStepKind.userApproval),
      TaskStepRecord(kind: TaskStepKind.commitOrPr),
    ];
