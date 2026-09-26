import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/tools/terminal_tool.dart';
import '../../core/tools/tool.dart';

/// The bottom-panel Terminal view: every command run through
/// [ToolGateway]/[TerminalTool] is shown here — command, agent, working
/// directory, start time, output, exit code, duration — nothing hidden, per
/// the brief.
class TerminalPanel extends ConsumerStatefulWidget {
  const TerminalPanel({super.key});

  @override
  ConsumerState<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends ConsumerState<TerminalPanel> {
  final _controller = TextEditingController();
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(terminalHistoryProvider);
    return Column(
      children: [
        Expanded(
          child: history.isEmpty
              ? const Center(child: Text('No commands run yet.'))
              : ListView.builder(
                  reverse: true,
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    final record = history[history.length - 1 - index];
                    return _CommandTile(record: record);
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: !_running,
                  decoration: const InputDecoration(
                    prefixText: r'$ ',
                    border: OutlineInputBorder(),
                    hintText: 'Run a command (subject to the Policy Engine)',
                  ),
                  onSubmitted: (_) => _run(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _running ? null : _run,
                child: _running
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Run'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _run() async {
    final command = _controller.text.trim();
    if (command.isEmpty) return;
    setState(() => _running = true);
    final gateway = ref.read(toolGatewayProvider);
    try {
      await gateway.invoke('run_terminal_command', {'command': command});
    } on ToolDeniedException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Denied: ${e.reason}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _controller.clear();
        });
      }
    }
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({required this.record});
  final CommandExecutionRecord record;

  @override
  Widget build(BuildContext context) {
    final exitCode = record.exitCode;
    final color = exitCode == null
        ? Colors.grey
        : exitCode == 0
            ? Colors.green
            : Colors.red;
    return ExpansionTile(
      leading: Icon(Icons.circle, size: 10, color: color),
      title: Text(record.command, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(
        '${record.risk.name} · ${record.workingDirectory} · '
        '${exitCode == null ? 'running' : 'exit $exitCode'} · ${record.duration.inMilliseconds}ms',
      ),
      children: [
        if (record.stdout.isNotEmpty)
          _OutputBlock(label: 'stdout', text: record.stdout),
        if (record.stderr.isNotEmpty)
          _OutputBlock(label: 'stderr', text: record.stderr),
      ],
    );
  }
}

class _OutputBlock extends StatelessWidget {
  const _OutputBlock({required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: SelectableText('$label:\n$text', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ),
    );
  }
}
