import 'dart:io';

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
    TerminalLog? log,
    CommandClassifier? classifier,
  })  : _log = log,
        _classifier = classifier ?? CommandClassifier();

  final String workingDirectory;
  final String agentId;
  final TerminalLog? _log;
  final CommandClassifier _classifier;

  final List<CommandExecutionRecord> history = [];

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
    final record = CommandExecutionRecord(
      command: command,
      agentId: agentId,
      workingDirectory: workingDirectory,
      startedAt: DateTime.now(),
      risk: _classifier.classify(command),
    );
    history.add(record);
    _log?.call(record);

    try {
      final result = await Process.run(
        '/bin/sh',
        ['-c', command],
        workingDirectory: workingDirectory,
      );
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
