import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/browser/playwright_mcp.dart';
import '../../core/tools/tool.dart';

/// The Browser section: connects to the real Playwright MCP server
/// (`npx -y @playwright/mcp@latest`) via the existing MCP infrastructure —
/// see `lib/core/browser/playwright_mcp.dart` for why this is the
/// integration strategy rather than a bespoke CDP client, and for the live
/// tool-discovery run this reproduces (25 `browser_*` tools). Requires
/// Node.js (`npx`) on PATH; the MCP server itself downloads/manages the
/// Playwright browser binaries on first real navigation.
class BrowserPanel extends ConsumerStatefulWidget {
  const BrowserPanel({super.key});

  @override
  ConsumerState<BrowserPanel> createState() => _BrowserPanelState();
}

class _BrowserPanelState extends ConsumerState<BrowserPanel> {
  bool _connecting = false;
  String? _error;
  final _urlController = TextEditingController(text: 'https://example.com');
  String? _lastResult;

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(mcpManagerProvider);
    final connection = manager.connections.where((c) => c.config.id == 'playwright').firstOrNull;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (connection == null) ...[
            const Text('Not connected to a browser automation server.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.public),
              label: const Text('Connect Playwright (npx @playwright/mcp)'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 8),
            const Text(
              'Requires Node.js (`npx`) on PATH. The server is spawned as a real '
              'subprocess through the same StdioMcpTransport every MCP server uses.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ] else ...[
            Row(
              children: [
                Icon(connection.isConnected ? Icons.check_circle : Icons.error, color: connection.isConnected ? Colors.green : Colors.red),
                const SizedBox(width: 8),
                Text('Connected — ${connection.client.tools.length} tools discovered'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(labelText: 'URL', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => _callTool('browser_navigate', {'url': _urlController.text}), child: const Text('Navigate')),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(onPressed: () => _callTool('browser_snapshot', {}), child: const Text('Accessibility snapshot')),
                OutlinedButton(onPressed: () => _callTool('browser_console_messages', {}), child: const Text('Console messages')),
                OutlinedButton(onPressed: () => _callTool('browser_network_requests', {}), child: const Text('Network requests')),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(_lastResult ?? '(no action run yet)'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref.read(mcpManagerProvider).addServer(playwrightMcpServerConfig());
    } catch (e) {
      setState(() => _error = 'Could not start Playwright MCP: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _callTool(String toolName, Map<String, dynamic> arguments) async {
    final manager = ref.read(mcpManagerProvider);
    manager.registerAllTools(ref.read(toolGatewayProvider).register);
    try {
      final result = await ref.read(toolGatewayProvider).invoke('mcp__playwright__$toolName', arguments);
      setState(() => _lastResult = result.body);
    } on ToolDeniedException catch (e) {
      setState(() => _lastResult = 'Denied: ${e.reason}');
    } catch (e) {
      setState(() => _lastResult = 'Error: $e');
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
