import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/tasks/task.dart';

final taskListProvider = FutureProvider.autoDispose<List<Task>>((ref) async {
  return ref.watch(taskManagerProvider).listTasks();
});

/// The Tasks section: every substantial request Forge has tracked, with its
/// live step checklist — the concrete UI for "Every substantial request
/// becomes a Task" / "Display progress live."
class TasksPanel extends ConsumerWidget {
  const TasksPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(taskListProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New task'),
        onPressed: () => _showCreateTaskDialog(context, ref),
      ),
      body: tasksAsync.when(
        data: (tasks) => tasks.isEmpty
            ? const Center(child: Text('No tasks yet. Create one to get started.'))
            : ListView.builder(
                itemCount: tasks.length,
                itemBuilder: (context, index) => _TaskTile(task: tasks[index]),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) => Center(child: Text('Failed to load tasks: $err')),
      ),
    );
  }

  Future<void> _showCreateTaskDialog(BuildContext context, WidgetRef ref) async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New task'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
        ],
      ),
    );
    if (created == true && titleController.text.trim().isNotEmpty) {
      await ref.read(taskManagerProvider).createTask(
            title: titleController.text.trim(),
            description: descriptionController.text.trim(),
          );
      ref.invalidate(taskListProvider);
    }
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});
  final Task task;

  @override
  Widget build(BuildContext context) {
    final done = task.steps.where((s) => s.status == StepStatus.done).length;
    return ExpansionTile(
      title: Text(task.title),
      subtitle: Text('${task.status.name} · $done/${task.steps.length} steps'),
      leading: _StatusIcon(status: task.status),
      children: task.steps
          .map((step) => ListTile(
                dense: true,
                leading: _StepStatusIcon(status: step.status),
                title: Text(step.kind.name),
                subtitle: step.note.isEmpty ? null : Text(step.note),
              ))
          .toList(),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      TaskStatus.completed => (Icons.check_circle, Colors.green),
      TaskStatus.failed => (Icons.error, Colors.red),
      TaskStatus.blocked => (Icons.pause_circle, Colors.orange),
      TaskStatus.running => (Icons.autorenew, Colors.blue),
      TaskStatus.cancelled => (Icons.cancel, Colors.grey),
      TaskStatus.pending => (Icons.schedule, Colors.grey),
    };
    return Icon(icon, color: color);
  }
}

class _StepStatusIcon extends StatelessWidget {
  const _StepStatusIcon({required this.status});
  final StepStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      StepStatus.done => (Icons.check, Colors.green),
      StepStatus.failed => (Icons.close, Colors.red),
      StepStatus.inProgress => (Icons.play_arrow, Colors.blue),
      StepStatus.skipped => (Icons.fast_forward, Colors.grey),
      StepStatus.pending => (Icons.circle_outlined, Colors.grey),
    };
    return Icon(icon, color: color, size: 18);
  }
}
