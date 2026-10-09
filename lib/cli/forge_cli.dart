import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../core/git/git_service.dart';
import '../core/mcp/mcp_manager.dart';
import '../core/models/chat_types.dart';
import '../core/models/model_registry.dart';
import '../core/models/model_router.dart';
import '../core/models/providers/nvidia_nim_provider.dart';
import '../core/models/task_classifier.dart';
import '../core/observability/telemetry_store.dart';
import '../core/project/project_manager.dart';
import '../core/security/secrets_store.dart';
import '../core/tasks/task.dart';
import '../core/tasks/task_manager.dart';
import '../core/tasks/task_store.dart';

/// Entry point shared by the `forge`/`aiwork` executable and any future GUI
/// "run a CLI command" affordance. The brief is explicit that "The GUI and
/// CLI must use the SAME backend agent engine" — this file only ever calls
/// into `lib/core/**`, never anything GUI-specific, so both surfaces are
/// thin front ends over one engine.
Future<int> runForgeCli(List<String> arguments) async {
  final runner = CommandRunner<int>(
    'forge',
    'Forge — standalone AI software-engineering workstation (CLI).',
  )
    ..addCommand(OpenCommand())
    ..addCommand(AskCommand())
    ..addCommand(TaskCommand())
    ..addCommand(ReviewCommand())
    ..addCommand(ModelsCommand())
    ..addCommand(McpCommand())
    ..addCommand(StatusCommand())
    ..addCommand(ResumeCommand())
    ..addCommand(ObservatoryCommand());

  try {
    final result = await runner.run(arguments);
    return result ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  }
}

class OpenCommand extends Command<int> {
  @override
  final name = 'open';
  @override
  final description = 'Open a project directory and print its Project Intelligence Profile.';

  @override
  Future<int> run() async {
    final positional = argResults!.rest;
    final requested = positional.isNotEmpty ? positional.first : '.';
    late final String root;
    try {
      root = await ProjectManager().open(requested);
    } on ProjectNotFoundException catch (e) {
      stderr.writeln(e);
      return 1;
    }
    stdout.writeln('Project: $root');

    final markers = <String, String>{
      'pubspec.yaml': 'Flutter/Dart',
      'package.json': 'Node.js',
      'Cargo.toml': 'Rust',
      'go.mod': 'Go',
      'requirements.txt': 'Python',
      'Gemfile': 'Ruby',
      'pom.xml': 'Java (Maven)',
      'build.gradle': 'Java/Kotlin (Gradle)',
    };
    final detected = <String>[];
    for (final entry in markers.entries) {
      if (File(p.join(root, entry.key)).existsSync()) detected.add(entry.value);
    }
    stdout.writeln('Detected stack: ${detected.isEmpty ? 'unknown' : detected.join(', ')}');

    final isGitRepo = Directory(p.join(root, '.git')).existsSync();
    stdout.writeln('Git repository: $isGitRepo');
    if (isGitRepo) {
      final git = GitService(repositoryRoot: root);
      try {
        stdout.writeln('Current branch: ${await git.currentBranch()}');
        final status = await git.status();
        stdout.writeln('Changed files: ${status.length}');
      } on GitException catch (e) {
        stdout.writeln('(git status unavailable: $e)');
      }
    }

    final hasTests = Directory(p.join(root, 'test')).existsSync() ||
        Directory(p.join(root, 'tests')).existsSync();
    stdout.writeln('Test directory present: $hasTests');
    return 0;
  }
}

class AskCommand extends Command<int> {
  @override
  final name = 'ask';
  @override
  final description = 'Ask a one-shot question, routed to the strongest suitable free model.';

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('Usage: forge ask "<question>"');
      return 64;
    }
    final question = argResults!.rest.join(' ');
    final registry = ModelRegistry();
    final secretsStore = InMemorySecretsStore();
    final provider = NvidiaNimProvider(secretsStore: secretsStore);
    stdout.writeln('Routing question to NVIDIA NIM...');
    try {
      await registry.refreshFromProvider(provider);
    } catch (e) {
      stderr.writeln('Could not reach NVIDIA NIM (${e.runtimeType}): $e');
      stderr.writeln('Configure an API key first (see PROVIDERS.md / Settings panel).');
      return 1;
    }
    final router = ModelRouter(registry: registry);
    RegisteredModel model;
    try {
      model = router.selectModel(TaskCategory.simpleCode);
    } on NoSuitableModelException catch (e) {
      stderr.writeln('No suitable model available: $e');
      return 1;
    }
    try {
      final result = await provider.chat(
        model.id.modelName,
        ChatRequest(messages: [ChatMessage.user(question)]),
      );
      stdout.writeln(result.message.content);
      return 0;
    } catch (e) {
      stderr.writeln('Model call failed: $e');
      return 1;
    }
  }
}

class TaskCommand extends Command<int> {
  @override
  final name = 'task';
  @override
  final description = 'Create a new tracked Task for a description of work.';

  TaskCommand() {
    argParser.addOption('dir', help: 'Project directory (defaults to cwd)', defaultsTo: '.');
  }

  @override
  Future<int> run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('Usage: forge task "<description>"');
      return 64;
    }
    final root = p.normalize(p.absolute(argResults!['dir'] as String));
    final manager = TaskManager(FileTaskStore(root));
    final description = argResults!.rest.join(' ');
    final task = await manager.createTask(
      title: description.length > 60 ? '${description.substring(0, 57)}...' : description,
      description: description,
    );
    stdout.writeln('Created task ${task.id}');
    for (final step in task.steps) {
      stdout.writeln('  [ ] ${step.kind.name}');
    }
    stdout.writeln('\nRun `forge status --dir $root` to check progress, or `forge resume` after a restart.');
    return 0;
  }
}

class ReviewCommand extends Command<int> {
  @override
  final name = 'review';
  @override
  final description = 'Show the review-package summary for a task (independent + Claude final review).';

  ReviewCommand() {
    argParser
      ..addOption('dir', help: 'Project directory (defaults to cwd)', defaultsTo: '.')
      ..addOption('task', help: 'Task id to review', mandatory: true);
  }

  @override
  Future<int> run() async {
    final root = p.normalize(p.absolute(argResults!['dir'] as String));
    final manager = TaskManager(FileTaskStore(root));
    final task = await manager.store.load(argResults!['task'] as String);
    if (task == null) {
      stderr.writeln('No such task.');
      return 1;
    }
    stdout.writeln('Task: ${task.title}');
    stdout.writeln('Status: ${task.status.name}');
    stdout.writeln('Review cycles used: ${task.reviewCycleCount}/${task.maxReviewCycles}');
    stdout.writeln(
      'Independent review and Claude Final Review run automatically once the '
      'independentReview/finalReview steps are reached by the agent runtime; '
      'this command surfaces their recorded state for inspection.',
    );
    final independent = task.steps.firstWhere(
      (s) => s.kind == TaskStepKind.independentReview,
      orElse: () => TaskStepRecord(kind: TaskStepKind.independentReview),
    );
    final finalReview = task.steps.firstWhere(
      (s) => s.kind == TaskStepKind.finalReview,
      orElse: () => TaskStepRecord(kind: TaskStepKind.finalReview),
    );
    stdout.writeln('Independent review: ${independent.status.name} ${independent.note}');
    stdout.writeln('Claude final review: ${finalReview.status.name} ${finalReview.note}');
    return 0;
  }
}

class ModelsCommand extends Command<int> {
  @override
  final name = 'models';
  @override
  final description = 'List models available from configured providers.';

  @override
  Future<int> run() async {
    final registry = ModelRegistry();
    final provider = NvidiaNimProvider(secretsStore: InMemorySecretsStore());
    try {
      await registry.refreshFromProvider(provider);
    } catch (e) {
      stderr.writeln('NVIDIA NIM unreachable or unauthenticated: $e');
    }
    if (registry.all.isEmpty) {
      stdout.writeln('No models registered. Configure a provider API key first.');
      return 0;
    }
    for (final model in registry.all) {
      stdout.writeln(
        '${model.id.key.padRight(50)} ctx=${model.capabilities.contextWindowTokens} '
        'tools=${model.capabilities.supportsToolCalling} free=${model.capabilities.isFree} '
        'available=${model.available}',
      );
    }
    return 0;
  }
}

class McpCommand extends Command<int> {
  @override
  final name = 'mcp';
  @override
  final description = 'Manage MCP servers.';

  McpCommand() {
    addSubcommand(_McpListCommand());
  }
}

class _McpListCommand extends Command<int> {
  @override
  final name = 'list';
  @override
  final description = 'List configured MCP servers from .forge/mcp.json.';

  _McpListCommand() {
    argParser.addOption('dir', help: 'Project directory (defaults to cwd)', defaultsTo: '.');
  }

  @override
  Future<int> run() async {
    final root = p.normalize(p.absolute(argResults!['dir'] as String));
    final configFile = File(p.join(root, '.forge', 'mcp.json'));
    if (!configFile.existsSync()) {
      stdout.writeln('No MCP servers configured (no .forge/mcp.json).');
      return 0;
    }
    final entries = jsonDecode(await configFile.readAsString()) as List<dynamic>;
    final manager = McpManager();
    for (final entry in entries) {
      final map = entry as Map<String, dynamic>;
      await manager.addServer(McpServerConfig(
        id: map['id'] as String,
        name: map['name'] as String,
        command: map['command'] as String,
        args: (map['args'] as List<dynamic>? ?? const []).cast<String>(),
        trusted: map['trusted'] as bool? ?? false,
      ));
    }
    for (final connection in manager.connections) {
      stdout.writeln(
        '${connection.config.name.padRight(20)} '
        '${connection.isConnected ? 'connected' : 'disconnected'} '
        '${connection.config.trusted ? '' : '(untrusted)'} '
        'tools=${connection.client.tools.length}',
      );
    }
    return 0;
  }
}

class StatusCommand extends Command<int> {
  @override
  final name = 'status';
  @override
  final description = 'Show project, Git, and task status.';

  StatusCommand() {
    argParser.addOption('dir', help: 'Project directory (defaults to cwd)', defaultsTo: '.');
  }

  @override
  Future<int> run() async {
    final root = p.normalize(p.absolute(argResults!['dir'] as String));
    stdout.writeln('Project: $root');
    final git = GitService(repositoryRoot: root);
    try {
      stdout.writeln('Branch: ${await git.currentBranch()}');
      final status = await git.status();
      stdout.writeln('Changed files: ${status.length}');
    } on GitException {
      stdout.writeln('(not a git repository, or git unavailable)');
    }
    final manager = TaskManager(FileTaskStore(root));
    final tasks = await manager.listTasks();
    stdout.writeln('Tasks: ${tasks.length}');
    for (final task in tasks.take(10)) {
      stdout.writeln('  ${task.id}  ${task.status.name.padRight(10)}  ${task.title}');
    }
    return 0;
  }
}

class ResumeCommand extends Command<int> {
  @override
  final name = 'resume';
  @override
  final description = 'List tasks that can be resumed after a restart.';

  ResumeCommand() {
    argParser.addOption('dir', help: 'Project directory (defaults to cwd)', defaultsTo: '.');
  }

  @override
  Future<int> run() async {
    final root = p.normalize(p.absolute(argResults!['dir'] as String));
    final manager = TaskManager(FileTaskStore(root));
    final resumable = await manager.resumableTasks();
    if (resumable.isEmpty) {
      stdout.writeln('No interrupted tasks to resume.');
      return 0;
    }
    for (final task in resumable) {
      final last = task.lastCompletedStep;
      stdout.writeln(
        '${task.id}  ${task.title}\n'
        '  status: ${task.status.name}\n'
        '  last completed step: ${last?.kind.name ?? '(none)'}\n'
        '  branch: ${task.branch ?? '(none)'}',
      );
    }
    return 0;
  }
}

/// `forge observatory` — a headless Neural Observatory summary for the
/// current project: aggregates the persisted JSONL telemetry (the same
/// store the desktop Observatory reads) into per-model request counts,
/// latency percentiles, token totals and cost availability. Everything
/// printed comes from recorded spans; an empty store says so plainly
/// rather than inventing a table.
class ObservatoryCommand extends Command<int> {
  @override
  final name = 'observatory';
  @override
  final description =
      'Print a Neural Observatory summary from persisted telemetry.';

  @override
  Future<int> run() async {
    final store = JsonlTelemetryStore(Directory.current.path);
    final events = await store.readAll();
    if (events.isEmpty) {
      stdout.writeln(
          'No telemetry recorded for this project yet (.forge/observability/).');
      stdout.writeln(
          'Telemetry accumulates as instrumented sessions, agent runs and '
          'provider requests happen.');
      return 0;
    }

    final sessions = <String>{};
    final models = <String, _ModelAggregate>{};
    var toolCalls = 0;
    var toolFailures = 0;
    var networkEvents = 0;

    for (final event in events) {
      final name = event['name'] as String?;
      final sessionId = event['sessionId'] as String?;
      if (sessionId != null && sessionId != 'global') sessions.add(sessionId);
      // Attributes are mixed JSON types (strings, numbers, booleans) —
      // cast to dynamic values, then read each field by its real type.
      final attributes = (event['attributes'] as Map?)?.cast<String, dynamic>();
      switch (name) {
        case 'model.request':
          final model = attributes?['model'] as String? ?? 'unknown';
          final aggregate =
              models.putIfAbsent(model, () => _ModelAggregate());
          aggregate.requests++;
          final latency = (attributes?['latencyMs'] as num?)?.toDouble();
          if (latency != null) aggregate.latencies.add(latency);
          if (attributes?['succeeded'] == false) aggregate.failures++;
          if (attributes?['rateLimited'] == true) aggregate.rateLimited++;
          aggregate.promptTokens +=
              (attributes?['promptTokens'] as num?)?.toInt() ?? 0;
          aggregate.completionTokens +=
              (attributes?['completionTokens'] as num?)?.toInt() ?? 0;
          final cost = attributes?['costUsd'] as num?;
          if (cost != null) {
            aggregate.costKnown = true;
            aggregate.costUsd += cost.toDouble();
          } else {
            aggregate.costKnown = false;
          }
        case 'tool.call':
          toolCalls++;
          if (attributes?['succeeded'] == false) toolFailures++;
        case 'network.traffic':
          networkEvents++;
        default:
          break;
      }
    }

    final latencies = models.values
        .expand((a) => a.latencies)
        .toList(growable: false)
      ..sort();
    double? percentile(List<double> sorted, double q) => sorted.isEmpty
        ? null
        : sorted[((q * (sorted.length - 1)).floor())];

    stdout.writeln('Sessions retained: ${sessions.length}');
    stdout.writeln('Model requests: '
        '${models.values.map((a) => a.requests).fold(0, (a, b) => a + b)}');
    stdout.writeln('Tool calls: $toolCalls ($toolFailures failed)');
    stdout.writeln('Network traffic events: $networkEvents');
    if (latencies.isNotEmpty) {
      final p50 = percentile(latencies, 0.50)!.round();
      final p95 = percentile(latencies, 0.95)!.round();
      stdout.writeln('Request latency (measured): '
          'p50 ${p50}ms · p95 ${p95}ms over ${latencies.length} requests');
    }
    if (models.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln('Per-model (from persisted spans):');
      for (final entry in models.entries) {
        final a = entry.value;
        a.latencies.sort();
        stdout.writeln(
          '  ${entry.key}\n'
          '    requests: ${a.requests} · failures: ${a.failures} · '
          '429s: ${a.rateLimited}\n'
          '    tokens: ${a.promptTokens} in / ${a.completionTokens} out\n'
          '    cost: ${a.costKnown ? '\$${a.costUsd.toStringAsFixed(4)}' : 'unavailable (no configured pricing)'}',
        );
      }
    }
    return 0;
  }
}

class _ModelAggregate {
  int requests = 0;
  int failures = 0;
  int rateLimited = 0;
  int promptTokens = 0;
  int completionTokens = 0;
  bool costKnown = true;
  double costUsd = 0;
  final List<double> latencies = [];
}

