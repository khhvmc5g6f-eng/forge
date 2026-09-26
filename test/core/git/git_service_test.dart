import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/git/checkpoint.dart';
import 'package:forge/core/git/git_service.dart';

class _ScriptedProcessRunner implements ProcessRunner {
  final List<List<String>> calls = [];
  final Map<String, GitResult> _byArgsKey = {};

  void whenArgs(List<String> args, GitResult result) {
    _byArgsKey[args.join(' ')] = result;
  }

  @override
  Future<GitResult> run(String executable, List<String> args, String workingDirectory) async {
    calls.add(args);
    return _byArgsKey[args.join(' ')] ??
        const GitResult(exitCode: 0, stdout: '', stderr: '');
  }
}

GitResult ok(String stdout) => GitResult(exitCode: 0, stdout: stdout, stderr: '');

void main() {
  group('GitService', () {
    test('status parses porcelain output', () async {
      final runner = _ScriptedProcessRunner()
        ..whenArgs(['status', '--porcelain=v1'], ok(' M lib/main.dart\n?? lib/new_file.dart\n'));
      final git = GitService(repositoryRoot: '/repo', runner: runner);
      final files = await git.status();
      expect(files, hasLength(2));
      expect(files[0].path, 'lib/main.dart');
      expect(files[0].worktreeStatus, 'M');
      expect(files[1].indexStatus, '?');
    });

    test('currentBranch and currentCommit trim output', () async {
      final runner = _ScriptedProcessRunner()
        ..whenArgs(['rev-parse', '--abbrev-ref', 'HEAD'], ok('main\n'))
        ..whenArgs(['rev-parse', 'HEAD'], ok('abc1234\n'));
      final git = GitService(repositoryRoot: '/repo', runner: runner);
      expect(await git.currentBranch(), 'main');
      expect(await git.currentCommit(), 'abc1234');
    });

    test('a non-zero exit code throws GitException', () async {
      final runner = _ScriptedProcessRunner()
        ..whenArgs(['commit', '-m', 'x'],
            const GitResult(exitCode: 1, stdout: '', stderr: 'nothing to commit'));
      final git = GitService(repositoryRoot: '/repo', runner: runner);
      expect(() => git.commit('x'), throwsA(isA<GitException>()));
    });

    test('createWorktree issues the expected git worktree add command', () async {
      final runner = _ScriptedProcessRunner();
      final git = GitService(repositoryRoot: '/repo', runner: runner);
      await git.createWorktree('/tmp/wt', 'ai/task/1-fix', fromRef: 'abc123');
      expect(
        runner.calls,
        contains(equals(['worktree', 'add', '-b', 'ai/task/1-fix', '/tmp/wt', 'abc123'])),
      );
    });
  });

  group('CheckpointManager', () {
    test('create() captures branch, head commit, and dirty files', () async {
      final runner = _ScriptedProcessRunner()
        ..whenArgs(['rev-parse', '--abbrev-ref', 'HEAD'], ok('main\n'))
        ..whenArgs(['rev-parse', 'HEAD'], ok('deadbeef\n'))
        ..whenArgs(['status', '--porcelain=v1'], ok(' M lib/a.dart\n'));
      final git = GitService(repositoryRoot: '/repo', runner: runner);
      final manager = CheckpointManager(git);

      final checkpoint = await manager.create(taskId: 't1', label: 'before edit');
      expect(checkpoint.branch, 'main');
      expect(checkpoint.headCommitSha, 'deadbeef');
      expect(checkpoint.dirtyFilesAtCheckpoint, ['lib/a.dart']);
      expect(manager.forTask('t1'), hasLength(1));
    });

    test('rollbackToCheckpoint hard-resets to the recorded commit', () async {
      final runner = _ScriptedProcessRunner()
        ..whenArgs(['rev-parse', '--abbrev-ref', 'HEAD'], ok('main\n'))
        ..whenArgs(['rev-parse', 'HEAD'], ok('deadbeef\n'))
        ..whenArgs(['status', '--porcelain=v1'], ok(''));
      final git = GitService(repositoryRoot: '/repo', runner: runner);
      final manager = CheckpointManager(git);
      final checkpoint = await manager.create(taskId: 't1', label: 'ckpt');

      await manager.rollbackToCheckpoint(checkpoint);
      expect(runner.calls, contains(equals(['reset', '--hard', 'deadbeef'])));
    });

    test('rollbackTask throws when no checkpoints exist for the task', () {
      final git = GitService(repositoryRoot: '/repo', runner: _ScriptedProcessRunner());
      final manager = CheckpointManager(git);
      expect(() => manager.rollbackTask('missing'), throwsA(isA<StateError>()));
    });
  });
}
