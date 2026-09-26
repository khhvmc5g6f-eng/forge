import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/mcp/mcp_manager.dart';

/// The MCP section: add / remove / enable / disable / test servers, view
/// their discovered tools. Newly added servers default to `trusted: false`
/// per the brief — nothing here silently elevates a new server's tool
/// results above the same [PolicyEngine]/[UntrustedContent] treatment every
/// other tool gets.
class McpPanel extends ConsumerStatefulWidget {
  const McpPanel({super.key});

  @override
  ConsumerState<McpPanel> createState() => _McpPanelState();
}

class _McpPanelState extends ConsumerState<McpPanel> {
  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(mcpManagerProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
        onPressed: () => _showAddDialog(context, manager),
      ),
      body: manager.connections.isEmpty
          ? const Center(child: Text('No MCP servers configured.'))
          : ListView.builder(
              itemCount: manager.connections.length,
              itemBuilder: (context, index) {
                final connection = manager.connections[index];
                return ExpansionTile(
                  leading: Icon(
                    connection.isConnected ? Icons.link : Icons.link_off,
                    color: connection.isConnected ? Colors.green : Colors.grey,
                  ),
                  title: Text(connection.config.name),
                  subtitle: Text(
                    '${connection.config.command} ${connection.config.args.join(' ')}'
                    '${connection.config.trusted ? '' : '  ·  UNTRUSTED'}',
                  ),
                  children: [
                    if (connection.lastError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(connection.lastError!, style: const TextStyle(color: Colors.red)),
                      ),
                    ...connection.client.tools.map((t) => ListTile(
                          dense: true,
                          title: Text(t.name),
                          subtitle: Text(t.description),
                        )),
                    OverflowBar(
                      children: [
                        TextButton(
                          onPressed: () async {
                            await manager.testServer(connection.config.id);
                            setState(() {});
                          },
                          child: const Text('Test'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await manager.setEnabled(connection.config.id, !connection.config.enabled);
                            setState(() {});
                          },
                          child: Text(connection.config.enabled ? 'Disable' : 'Enable'),
                        ),
                        TextButton(
                          onPressed: () async {
                            await manager.removeServer(connection.config.id);
                            setState(() {});
                          },
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
    );
  }

  Future<void> _showAddDialog(BuildContext context, McpManager manager) async {
    final nameController = TextEditingController();
    final commandController = TextEditingController();
    final argsController = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add MCP server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Name')),
            TextField(
                controller: commandController,
                decoration: const InputDecoration(labelText: 'Command (e.g. npx)')),
            TextField(
                controller: argsController,
                decoration: const InputDecoration(labelText: 'Args (space-separated)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (added == true && nameController.text.trim().isNotEmpty) {
      await manager.addServer(McpServerConfig(
        id: nameController.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-'),
        name: nameController.text.trim(),
        command: commandController.text.trim(),
        args: argsController.text.trim().isEmpty ? const [] : argsController.text.trim().split(' '),
      ));
      setState(() {});
    }
  }
}
