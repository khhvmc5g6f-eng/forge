import 'git_service.dart';

/// A recoverable snapshot of repository state taken before a significant
/// modification, per the brief: "Before significant modifications create a
/// checkpoint. Store: Git commit, changed files, task, timestamp."
class Checkpoint {
  const Checkpoint({
    required this.id,
    required this.taskId,
    required this.branch,
    required this.headCommitSha,
    required this.dirtyFilesAtCheckpoint,
    required this.createdAt,
    required this.label,
  });

  final String id;
  final String taskId;
  final String branch;
  final String headCommitSha;
  final List<String> dirtyFilesAtCheckpoint;
  final DateTime createdAt;
  final String label;

  Map<String, dynamic> toJson() => {
        'id': id,
        'taskId': taskId,
        'branch': branch,
        'headCommitSha': headCommitSha,
        'dirtyFilesAtCheckpoint': dirtyFilesAtCheckpoint,
        'createdAt': createdAt.toIso8601String(),
        'label': label,
      };

  factory Checkpoint.fromJson(Map<String, dynamic> json) => Checkpoint(
        id: json['id'] as String,
        taskId: json['taskId'] as String,
        branch: json['branch'] as String,
        headCommitSha: json['headCommitSha'] as String,
        dirtyFilesAtCheckpoint:
            (json['dirtyFilesAtCheckpoint'] as List).cast<String>(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        label: json['label'] as String,
      );
}

/// Creates and restores [Checkpoint]s, and rollback of a whole task or a
/// single patch to a prior checkpoint. Never mutates history itself except
/// via [rollbackToCheckpoint], which is explicitly a destructive operation
/// the caller must have already cleared through the [PolicyEngine].
class CheckpointManager {
  CheckpointManager(this.git);

  final GitService git;
  final List<Checkpoint> _checkpoints = [];
  int _counter = 0;

  List<Checkpoint> get all => List.unmodifiable(_checkpoints);

  List<Checkpoint> forTask(String taskId) =>
      _checkpoints.where((c) => c.taskId == taskId).toList();

  Future<Checkpoint> create({required String taskId, required String label}) async {
    final branch = await git.currentBranch();
    final head = await git.currentCommit();
    final dirty = (await git.status()).map((f) => f.path).toList();
    final checkpoint = Checkpoint(
      id: 'ckpt_${DateTime.now().millisecondsSinceEpoch}_${_counter++}',
      taskId: taskId,
      branch: branch,
      headCommitSha: head,
      dirtyFilesAtCheckpoint: dirty,
      createdAt: DateTime.now(),
      label: label,
    );
    _checkpoints.add(checkpoint);
    return checkpoint;
  }

  /// Restores the working tree to exactly the state recorded at
  /// [checkpoint]: hard reset to its commit. Any commits made after the
  /// checkpoint on this branch are discarded from the working tree (they
  /// remain reachable via reflog, per Git's normal safety net, but Forge
  /// does not rely on that — this must only be invoked after explicit user
  /// confirmation of a destructive action).
  Future<void> rollbackToCheckpoint(Checkpoint checkpoint) async {
    await git.hardResetTo(checkpoint.headCommitSha);
  }

  /// Rolls back every change associated with [taskId] by restoring the
  /// earliest checkpoint recorded for it.
  Future<void> rollbackTask(String taskId) async {
    final checkpoints = forTask(taskId);
    if (checkpoints.isEmpty) {
      throw StateError('No checkpoints recorded for task $taskId');
    }
    checkpoints.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    await rollbackToCheckpoint(checkpoints.first);
  }
}

/// Creates an isolated `ai/task/<id>-<slug>` branch (or worktree) before
/// autonomous work begins, per the brief: "Autonomous work should normally
/// occur in isolated branches/worktrees... Never overwrite unrelated human
/// work."
class BranchIsolation {
  BranchIsolation(this.git);

  final GitService git;

  String branchNameFor(String taskId, String slug) {
    final safeSlug = slug
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'ai/task/$taskId-$safeSlug';
  }

  /// Creates the isolated branch from the current HEAD, recording the
  /// pre-existing branch and dirty state first so an aborted task can be
  /// cleanly abandoned without ever having touched the human's branch.
  Future<TaskWorkspace> prepare({required String taskId, required String slug}) async {
    final originalBranch = await git.currentBranch();
    final originalCommit = await git.currentCommit();
    final dirtyFiles = (await git.status()).map((f) => f.path).toList();
    final branchName = branchNameFor(taskId, slug);
    if (dirtyFiles.isNotEmpty) {
      // Never start autonomous work on top of the human's uncommitted
      // changes: stash them and restore on the original branch afterwards.
      await git.stash(message: 'forge-autosave-before-$taskId');
    }
    await git.createBranch(branchName, fromRef: originalCommit);
    return TaskWorkspace(
      taskId: taskId,
      originalBranch: originalBranch,
      originalCommit: originalCommit,
      isolatedBranch: branchName,
      stashedDirtyFiles: dirtyFiles,
    );
  }

  Future<void> restoreOriginal(TaskWorkspace workspace) async {
    await git.checkout(workspace.originalBranch);
    if (workspace.stashedDirtyFiles.isNotEmpty) {
      await git.stashPop();
    }
  }
}

class TaskWorkspace {
  const TaskWorkspace({
    required this.taskId,
    required this.originalBranch,
    required this.originalCommit,
    required this.isolatedBranch,
    required this.stashedDirtyFiles,
  });

  final String taskId;
  final String originalBranch;
  final String originalCommit;
  final String isolatedBranch;
  final List<String> stashedDirtyFiles;
}
