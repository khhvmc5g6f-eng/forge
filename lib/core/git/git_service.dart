import 'dart:io';

/// Result of a single `git` invocation.
class GitResult {
  const GitResult({required this.exitCode, required this.stdout, required this.stderr});
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get succeeded => exitCode == 0;
}

class GitException implements Exception {
  GitException(this.args, this.result);
  final List<String> args;
  final GitResult result;

  @override
  String toString() => 'git ${args.join(' ')} failed (${result.exitCode}): ${result.stderr}';
}

/// A single changed file as reported by `git status --porcelain`.
class ChangedFile {
  const ChangedFile({required this.path, required this.indexStatus, required this.worktreeStatus});
  final String path;
  final String indexStatus;
  final String worktreeStatus;
}

/// Thin, testable wrapper over the `git` CLI. Every Git-touching feature in
/// Forge (status view, AI Changes view, checkpoints, branch isolation) goes
/// through this so there is exactly one place that shells out to `git` and
/// exactly one place to swap the process runner for a fake in tests.
class GitService {
  GitService({required this.repositoryRoot, ProcessRunner? runner})
      : _runner = runner ?? _RealProcessRunner();

  final String repositoryRoot;
  final ProcessRunner _runner;

  Future<GitResult> _run(List<String> args) async {
    final result = await _runner.run('git', args, repositoryRoot);
    if (result.exitCode != 0) {
      throw GitException(args, result);
    }
    return result;
  }

  Future<String> currentBranch() async =>
      (await _run(['rev-parse', '--abbrev-ref', 'HEAD'])).stdout.trim();

  Future<String> currentCommit() async =>
      (await _run(['rev-parse', 'HEAD'])).stdout.trim();

  Future<List<ChangedFile>> status() async {
    final result = await _run(['status', '--porcelain=v1']);
    final lines = result.stdout.split('\n').where((l) => l.trim().isNotEmpty);
    return lines.map((line) {
      final indexStatus = line[0];
      final worktreeStatus = line[1];
      final path = line.substring(3).trim();
      return ChangedFile(
        path: path,
        indexStatus: indexStatus,
        worktreeStatus: worktreeStatus,
      );
    }).toList();
  }

  Future<String> diff({String? path, bool staged = false}) async {
    final args = ['diff', if (staged) '--staged', if (path != null) '--', if (path != null) path];
    return (await _run(args)).stdout;
  }

  Future<String> log({int limit = 20}) async =>
      (await _run(['log', '--oneline', '-n', '$limit'])).stdout;

  Future<List<String>> branches() async {
    final result = await _run(['branch', '--format=%(refname:short)']);
    return result.stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  }

  Future<void> createBranch(String name, {String? fromRef}) async {
    await _run(['checkout', '-b', name, if (fromRef != null) fromRef]);
  }

  Future<void> checkout(String ref) async => _run(['checkout', ref]);

  Future<void> stage(List<String> paths) async => _run(['add', ...paths]);

  Future<void> unstage(List<String> paths) async => _run(['restore', '--staged', ...paths]);

  Future<String> commit(String message, {String? authorTrailer}) async {
    final fullMessage = authorTrailer == null ? message : '$message\n\n$authorTrailer';
    await _run(['commit', '-m', fullMessage]);
    return currentCommit();
  }

  Future<void> stash({String? message}) async =>
      _run(['stash', 'push', if (message != null) ...['-m', message]]);

  Future<void> stashPop() async => _run(['stash', 'pop']);

  Future<void> restore(List<String> paths) async => _run(['restore', ...paths]);

  /// Reverts the working tree to [commitSha]. This is a destructive
  /// operation from the Tool Gateway's perspective — callers must route the
  /// request through [PolicyEngine] before calling this, never call it
  /// directly from agent code.
  Future<void> hardResetTo(String commitSha) async => _run(['reset', '--hard', commitSha]);

  Future<bool> isWorkingTreeClean() async => (await status()).isEmpty;

  Future<bool> branchExists(String name) async {
    final result = await _runner.run('git', ['rev-parse', '--verify', name], repositoryRoot);
    return result.exitCode == 0;
  }

  /// Creates an isolated worktree for autonomous work at [worktreePath] on a
  /// new branch [branchName], per the brief's "autonomous work should
  /// normally occur in isolated branches/worktrees".
  Future<void> createWorktree(String worktreePath, String branchName, {String? fromRef}) async {
    await _run(['worktree', 'add', '-b', branchName, worktreePath, if (fromRef != null) fromRef]);
  }

  Future<void> removeWorktree(String worktreePath) async {
    await _run(['worktree', 'remove', worktreePath, '--force']);
  }
}

/// Indirection over process execution so tests never spawn a real `git`
/// subprocess for pure logic tests, while production code always does.
abstract class ProcessRunner {
  Future<GitResult> run(String executable, List<String> args, String workingDirectory);
}

class _RealProcessRunner implements ProcessRunner {
  @override
  Future<GitResult> run(String executable, List<String> args, String workingDirectory) async {
    final result = await Process.run(executable, args, workingDirectory: workingDirectory);
    return GitResult(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }
}
