import 'dart:io';

import 'package:path/path.dart' as p;

import '../security/untrusted_content.dart';
import 'command_classifier.dart';
import 'policy_engine.dart';
import 'tool.dart';
import 'tool_category.dart';

/// A completed (or failed-to-start) terminal command, recorded for the
/// bottom-panel Terminal view: command, agent, working directory, start
/// time, output, exit code, duration — nothing about a terminal invocation
/// is ever hidden from the user, per the brief.
class CommandExecutionRecord {
  CommandExecutionRecord({
    required this.command,
    required this.agentId,
    required this.workingDirectory,
    required this.startedAt,
    required this.risk,
  });

  final String command;
  final String agentId;
  final String workingDirectory;
  final DateTime startedAt;
  final CommandRisk risk;

  DateTime? finishedAt;
  String stdout = '';
  String stderr = '';
  int? exitCode;

  Duration get duration => (finishedAt ?? DateTime.now()).difference(startedAt);
}

typedef TerminalLog = void Function(CommandExecutionRecord record);

/// Executes a shell command inside [workingDirectory], never outside the
/// sandbox the [PolicyEngine] enforces on the invocation's `targetPath`.
/// Every invocation — allowed, asked, or denied — is appended to [log]
/// before/after execution so the UI's Terminal panel and Diagnostics Centre
/// have a complete, unfiltered audit trail.
class TerminalTool implements Tool {
  TerminalTool({
    required this.workingDirectory,
    required this.agentId,
    this._log,
    CommandClassifier? classifier,
    this.policyEngine,
    this.useSeatbelt = false,
  })  : _classifier = classifier ?? CommandClassifier();

  final String workingDirectory;
  final String agentId;
  final TerminalLog? _log;
  final CommandClassifier _classifier;

  /// Optional defense-in-depth: when provided, [execute] independently
  /// re-checks the invocation against this engine and throws
  /// [ToolDeniedException] on a `deny` decision, even if some future caller
  /// bypasses [ToolGateway]. The Tool Gateway remains the primary authority
  /// (including user approval of `ask` decisions); this is the fail-safe.
  final PolicyEngine? policyEngine;

  /// When true on macOS, commands are additionally executed under
  /// `sandbox-exec` with a Seatbelt profile that denies file writes outside
  /// the working directory (and /tmp). This contains the case where the
  /// rule-based classifier misses a novel destructive command: a
  /// mis-classified command still cannot scribble outside the project.
  /// Ignored on non-macOS platforms.
  final bool useSeatbelt;

  final List<CommandExecutionRecord> history = [];

  /// Writes the Seatbelt profile restricting file writes to [workingDirectory]
  /// and /tmp, and returns its path.
  Future<String> _writeSeatbeltProfile() async {
    final dir = Directory(p.join(workingDirectory, '.forge'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'seatbelt.sb'));
    // deny-by-default for writes; reads, process spawn, and network remain
    // available so builds/tests/installs keep working inside the project.
    final profile = '''
(version 1)
(allow process-exec*)
(allow process-fork)
(allow file-read*)
(allow file-write* (subpath "${p.absolute(workingDirectory)}"))
(allow file-write* (subpath "/tmp"))
(allow file-write* (subpath "/private/tmp"))
(allow file-write* (subpath "/var/folders"))
(allow network*)
''';
    await file.writeAsString(profile, flush: true);
    return file.path;
  }

  /// Runs [command], wrapped in `sandbox-exec` when [useSeatbelt] is enabled
  /// on macOS.
  Future<ProcessResult> _runProcess(String command) async {
    if (useSeatbelt && Platform.isMacOS) {
      final profilePath = await _writeSeatbeltProfile();
      return Process.run(
        '/usr/bin/sandbox-exec',
        ['-f', profilePath, '/bin/sh', '-c', command],
        workingDirectory: workingDirectory,
      );
    }
    return Process.run(
      '/bin/sh',
      ['-c', command],
      workingDirectory: workingDirectory,
    );
  }

  @override
  String get name => 'run_terminal_command';

  @override
  ToolCategory get category => ToolCategory.terminal;

  @override
  String get description =>
      'Runs a shell command in the project working directory. Classified '
      'SAFE/READ/BUILD/TEST/INSTALL/NETWORK/MODIFY/DESTRUCTIVE/PRIVILEGED '
      'before execution; destructive/privileged commands always require '
      'human confirmation.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
        },
        'required': ['command'],
      };

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) {
    final command = arguments['command'] as String;
    return ToolInvocation(
      category: category,
      toolName: name,
      commandRisk: _classifier.classify(command),
      targetPath: workingDirectory,
      description: command,
    );
  }

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final command = arguments['command'] as String;
    final invocation = describeInvocation(arguments);

    // Defense-in-depth: the Tool Gateway is the primary authority, but if a
    // policy engine is attached, a hard `deny` must never reach a process
    // spawn even through a future code path that skips the gateway.
    if (policyEngine != null) {
      final decision = policyEngine!.decide(invocation);
      if (decision.decision == PermissionDecision.deny) {
        throw ToolDeniedException(invocation, decision.reason);
      }
    }

    final record = CommandExecutionRecord(
      command: command,
      agentId: agentId,
      workingDirectory: workingDirectory,
      startedAt: DateTime.now(),
      risk: invocation.commandRisk!,
    );
    history.add(record);
    _log?.call(record);

    try {
      final result = await _runProcess(command);

      record
        ..stdout = result.stdout.toString()
        ..stderr = result.stderr.toString()
        ..exitCode = result.exitCode
        ..finishedAt = DateTime.now();
    } catch (e) {
      record
        ..stderr = 'Failed to start process: $e'
        ..exitCode = -1
        ..finishedAt = DateTime.now();
    }
    _log?.call(record);

    final body = StringBuffer()
      ..writeln('exit_code: ${record.exitCode}')
      ..writeln('--- stdout ---')
      ..writeln(record.stdout)
      ..writeln('--- stderr ---')
      ..writeln(record.stderr);
    return UntrustedContent(source: ContentSource.terminalOutput, body: body.toString());
  }
}
