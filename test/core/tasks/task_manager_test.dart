import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/tasks/task.dart';
import 'package:forge/core/tasks/task_manager.dart';
import 'package:forge/core/tasks/task_store.dart';

void main() {
  late TaskManager manager;
  late InMemoryTaskStore store;

  setUp(() {
    store = InMemoryTaskStore();
    manager = TaskManager(store);
  });

  test('createTask persists a task with the default debug workflow steps', () async {
    final task = await manager.createTask(title: 'Fix CPU issue', description: 'Cockpit Core spikes CPU');
    expect(task.status, TaskStatus.pending);
    expect(task.steps, isNotEmpty);
    expect(task.steps.first.kind, TaskStepKind.plan);

    final reloaded = await store.load(task.id);
    expect(reloaded, isNotNull);
    expect(reloaded!.title, 'Fix CPU issue');
  });

  test('beginStep/completeStep updates step status and task status', () async {
    final task = await manager.createTask(title: 't', description: 'd');
    await manager.beginStep(task, TaskStepKind.plan);
    expect(task.status, TaskStatus.running);
    await manager.completeStep(task, TaskStepKind.plan, note: 'planned');
    final step = task.steps.firstWhere((s) => s.kind == TaskStepKind.plan);
    expect(step.status, StepStatus.done);
    expect(step.note, 'planned');
  });

  test('failStep blocks the task', () async {
    final task = await manager.createTask(title: 't', description: 'd');
    await manager.failStep(task, TaskStepKind.build, note: 'compile error');
    expect(task.status, TaskStatus.blocked);
  });

  test('repair loop stops after maxRepairIterations, never infinite', () async {
    final task = await manager.createTask(
      title: 't',
      description: 'd',
      steps: [TaskStepRecord(kind: TaskStepKind.diagnose)],
    );
    var canContinue = true;
    var iterations = 0;
    while (canContinue) {
      canContinue = await manager.recordRepairIteration(task);
      iterations++;
      if (iterations > 100) fail('repair loop did not terminate');
    }
    expect(task.repairIterationCount, task.maxRepairIterations);
    expect(task.status, TaskStatus.blocked);
  });

  test('review cycle budget is enforced independently of repair budget', () async {
    final task = await manager.createTask(title: 't', description: 'd');
    for (var i = 0; i < task.maxReviewCycles; i++) {
      await manager.recordReviewCycle(task);
    }
    expect(task.reviewBudgetExhausted, isTrue);
    expect(task.status, TaskStatus.blocked);
  });

  test('resumableTasks only returns running or blocked tasks', () async {
    final running = await manager.createTask(title: 'running', description: 'd');
    await manager.beginStep(running, TaskStepKind.plan);

    final completed = await manager.createTask(title: 'completed', description: 'd');
    await manager.complete(completed);

    final blocked = await manager.createTask(title: 'blocked', description: 'd');
    await manager.failStep(blocked, TaskStepKind.plan);

    final resumable = await manager.resumableTasks();
    final titles = resumable.map((t) => t.title).toSet();
    expect(titles, {'running', 'blocked'});
  });

  test('a task survives a simulated restart via FileTaskStore', () async {
    final tmpDir = Directory.systemTemp.createTempSync('forge_task_store_test');
    addTearDown(() => tmpDir.deleteSync(recursive: true));

    final fileStore = FileTaskStore(tmpDir.path);
    final firstManager = TaskManager(fileStore);
    final task = await firstManager.createTask(title: 'survives restart', description: 'd');
    await firstManager.beginStep(task, TaskStepKind.plan);
    await firstManager.completeStep(task, TaskStepKind.plan);

    // Simulate an application restart: a brand-new TaskManager/TaskStore
    // instance reading from disk, with no shared in-memory state.
    final restartedManager = TaskManager(FileTaskStore(tmpDir.path));
    final resumable = await restartedManager.listTasks();
    final recovered = resumable.firstWhere((t) => t.id == task.id);
    expect(recovered.lastCompletedStep?.kind, TaskStepKind.plan);
    expect(recovered.status, TaskStatus.running);
  });
}
