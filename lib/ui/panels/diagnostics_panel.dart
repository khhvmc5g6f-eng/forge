import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/tools/policy_engine.dart';

/// The Diagnostics Centre: the [ToolGateway] audit log — every tool call any
/// agent or the user made, its Policy Engine decision, and its outcome.
/// This is the concrete "failed tool calls / model errors" surface from the
/// brief; nothing about a tool invocation is filtered out of this view.
class DiagnosticsPanel extends ConsumerWidget {
  const DiagnosticsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gateway = ref.watch(toolGatewayProvider);
    final log = gateway.auditLog.reversed.toList();
    return log.isEmpty
        ? const Center(child: Text('No tool invocations recorded yet.'))
        : ListView.builder(
            itemCount: log.length,
            itemBuilder: (context, index) {
              final record = log[index];
              return ListTile(
                leading: _decisionIcon(record.decision.decision),
                title: Text(record.toolName),
                subtitle: Text(
                  '${record.decision.decision.name} · ${record.decision.reason}'
                  '${record.error != null ? '\nerror: ${record.error}' : ''}',
                ),
                isThreeLine: record.error != null,
              );
            },
          );
  }

  Widget _decisionIcon(PermissionDecision decision) {
    return switch (decision) {
      PermissionDecision.allow => const Icon(Icons.check_circle_outline, color: Colors.green),
      PermissionDecision.ask => const Icon(Icons.help_outline, color: Colors.orange),
      PermissionDecision.deny => const Icon(Icons.block, color: Colors.red),
    };
  }
}
