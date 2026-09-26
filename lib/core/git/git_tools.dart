import '../security/untrusted_content.dart';
import '../tools/policy_engine.dart';
import '../tools/tool.dart';
import '../tools/tool_category.dart';
import 'git_service.dart';

abstract class _GitTool implements Tool {
  _GitTool(this.git, this.repositoryRoot);

  final GitService git;
  final String repositoryRoot;

  @override
  ToolCategory get category => ToolCategory.git;

  /// Read-only git tools (status/diff/log/branches) only need Diagnose;
  /// mutating ones (stage/commit) require the Git-category default
  /// (Commit To AI Branch). Overridden to `false` by mutating subclasses.
  bool get isReadOnly => true;

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) => ToolInvocation(
        category: category,
        toolName: name,
        targetPath: repositoryRoot,
        description: name,
        explicitLevel: isReadOnly ? PermissionLevel.diagnose : null,
      );
}

class GitStatusTool extends _GitTool {
  GitStatusTool(super.git, super.repositoryRoot);
  @override
  String get name => 'git_status';
  @override
  String get description => 'Shows changed files (git status --porcelain).';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object', 'properties': {}};
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final files = await git.status();
    final body = files.map((f) => '${f.indexStatus}${f.worktreeStatus} ${f.path}').join('\n');
    return UntrustedContent(source: ContentSource.toolResult, body: body);
  }
}

class GitDiffTool extends _GitTool {
  GitDiffTool(super.git, super.repositoryRoot);
  @override
  String get name => 'git_diff';
  @override
  String get description => 'Shows the diff for a path, or the whole working tree if omitted.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
          'staged': {'type': 'boolean'},
        },
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final diff = await git.diff(
      path: arguments['path'] as String?,
      staged: arguments['staged'] as bool? ?? false,
    );
    return UntrustedContent(source: ContentSource.toolResult, body: diff);
  }
}

class GitLogTool extends _GitTool {
  GitLogTool(super.git, super.repositoryRoot);
  @override
  String get name => 'git_log';
  @override
  String get description => 'Shows recent commit history (oneline).';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer'},
        },
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final limit = (arguments['limit'] as num?)?.toInt() ?? 20;
    return UntrustedContent(source: ContentSource.toolResult, body: await git.log(limit: limit));
  }
}

class GitBranchesTool extends _GitTool {
  GitBranchesTool(super.git, super.repositoryRoot);
  @override
  String get name => 'git_branches';
  @override
  String get description => 'Lists local branches.';
  @override
  Map<String, dynamic> get parametersSchema => const {'type': 'object', 'properties': {}};
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final branches = await git.branches();
    return UntrustedContent(source: ContentSource.toolResult, body: branches.join('\n'));
  }
}

class GitStageTool extends _GitTool {
  GitStageTool(super.git, super.repositoryRoot);
  @override
  bool get isReadOnly => false;
  @override
  String get name => 'git_stage';
  @override
  String get description => 'Stages the given paths.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'paths': {'type': 'array', 'items': {'type': 'string'}},
        },
        'required': ['paths'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final paths = (arguments['paths'] as List).cast<String>();
    await git.stage(paths);
    return UntrustedContent(source: ContentSource.toolResult, body: 'Staged ${paths.length} file(s)');
  }
}

class GitCommitTool extends _GitTool {
  GitCommitTool(super.git, super.repositoryRoot);
  @override
  bool get isReadOnly => false;
  @override
  String get name => 'git_commit';
  @override
  String get description => 'Commits currently staged changes.';
  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'message': {'type': 'string'},
        },
        'required': ['message'],
      };
  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final sha = await git.commit(arguments['message'] as String);
    return UntrustedContent(source: ContentSource.toolResult, body: 'Committed $sha');
  }
}

void registerGitTools(void Function(Tool) register, GitService git, String repositoryRoot) {
  register(GitStatusTool(git, repositoryRoot));
  register(GitDiffTool(git, repositoryRoot));
  register(GitLogTool(git, repositoryRoot));
  register(GitBranchesTool(git, repositoryRoot));
  register(GitStageTool(git, repositoryRoot));
  register(GitCommitTool(git, repositoryRoot));
}
