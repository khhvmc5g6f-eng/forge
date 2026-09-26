import 'package:uuid/uuid.dart';

import 'task.dart';
import 'task_store.dart';

/// Creates, tracks, and persists [Task]s. This is the concrete home of the
/// brief's "Every substantial request becomes a Task" requirement, and the
/// thing a restarted application queries to offer "RESUME TASK".
class TaskManager {
  TaskManager(this.store);

  final TaskStore store;
  final _uuid = const Uuid();

  Future<Task> createTask({
    required String title,
    required String description,
    List<TaskStepRecord>? steps,
  }) async {
    final task = Task(
      id: 't_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}',
      title: title,
      description: description,
      createdAt: DateTime.now(),
      steps: steps ?? defaultDebugWorkflowSteps(),
    );
    await store.save(task);
    return task;
  }

  Future<List<Task>> listTasks() => store.loadAll();

  Future<List<Task>> resumableTasks() async {
    final tasks = await store.loadAll();
    return tasks
        .where((t) => t.status == TaskStatus.running || t.status == TaskStatus.blocked)
        .toList();
  }

  Future<void> beginStep(Task task, TaskStepKind kind) async {
    final step = task.steps.firstWhere((s) => s.kind == kind);
    step.status = StepStatus.inProgress;
    task.status = TaskStatus.running;
    await store.save(task);
  }

  Future<void> completeStep(Task task, TaskStepKind kind, {String note = ''}) async {
    final step = task.steps.firstWhere((s) => s.kind == kind);
    step.status = StepStatus.done;
    step.note = note;
    await store.save(task);
  }

  Future<void> failStep(Task task, TaskStepKind kind, {String note = ''}) async {
    final step = task.steps.firstWhere((s) => s.kind == kind);
    step.status = StepStatus.failed;
    step.note = note;
    task.status = TaskStatus.blocked;
    await store.save(task);
  }

  /// Records one repair-loop iteration and blocks the task if the budget is
  /// exhausted, per the brief's "Do not allow infinite repair loops."
  Future<bool> recordRepairIteration(Task task) async {
    task.repairIterationCount++;
    if (task.repairBudgetExhausted) {
      task.status = TaskStatus.blocked;
    }
    await store.save(task);
    return !task.repairBudgetExhausted;
  }

  /// Records one Worker<->Reviewer rework cycle; returns false once the
  /// configurable maximum has been reached.
  Future<bool> recordReviewCycle(Task task) async {
    task.reviewCycleCount++;
    if (task.reviewBudgetExhausted) {
      task.status = TaskStatus.blocked;
    }
    await store.save(task);
    return !task.reviewBudgetExhausted;
  }

  Future<void> complete(Task task) async {
    task.status = TaskStatus.completed;
    await store.save(task);
  }

  Future<void> cancel(Task task) async {
    task.status = TaskStatus.cancelled;
    await store.save(task);
  }

  Future<void> recordCheckpoint(Task task, String checkpointId) async {
    task.checkpointIds.add(checkpointId);
    await store.save(task);
  }

  Future<void> recordAgent(Task task, String agentId) async {
    if (!task.involvedAgentIds.contains(agentId)) {
      task.involvedAgentIds.add(agentId);
      await store.save(task);
    }
  }

  Future<void> recordModelUsed(Task task, String modelKey) async {
    if (!task.modelIdsUsed.contains(modelKey)) {
      task.modelIdsUsed.add(modelKey);
      await store.save(task);
    }
  }
}
