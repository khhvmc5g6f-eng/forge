import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/browser/playwright_mcp.dart';
import 'package:forge/core/mcp/mcp_manager.dart';
import 'package:forge/core/mcp/mcp_transport.dart';
import 'package:forge/core/tools/tool_category.dart';

/// Waits a microtask turn so a [FakeMcpTransport]'s queued `sent` request has
/// actually been appended before the test inspects it.
Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// Finds the most recent request for [method] sent on [transport] and pushes
/// [result] back as its JSON-RPC response.
Future<void> _respond(FakeMcpTransport transport, String method, Map<String, dynamic> result) async {
  await _flush();
  final request = transport.sent.lastWhere((m) => m['method'] == method);
  transport.pushIncoming({'jsonrpc': '2.0', 'id': request['id'], 'result': result});
  await _flush();
}

void main() {
  test('playwrightMcpServerConfig() is tagged as an untrusted playwright-category server', () {
    final config = playwrightMcpServerConfig();
    expect(config.category, McpServerCategory.playwright);
    expect(config.trusted, isFalse);
    expect(config.command, 'npx');
    expect(config.args, contains('@playwright/mcp@latest'));
    expect(config.args, contains('--headless'));
  });

  test('tools from a playwright-category server register under ToolCategory.browser', () async {
    final transport = FakeMcpTransport();
    final manager = McpManager(transportFactory: (_) => transport);
    final connectFuture = manager.addServer(playwrightMcpServerConfig());

    await _respond(transport, 'initialize', {'serverInfo': {'name': 'Playwright'}});
    await _respond(transport, 'tools/list', {
      'tools': [
        {
          'name': 'browser_navigate',
          'description': 'Navigate to a URL',
          'inputSchema': {'type': 'object', 'properties': {'url': {'type': 'string'}}},
        },
        {
          'name': 'browser_take_screenshot',
          'description': 'Take a screenshot of the current page.',
          'inputSchema': {'type': 'object', 'properties': {}},
        },
      ],
    });
    await _respond(transport, 'resources/list', {'resources': []});
    await _respond(transport, 'prompts/list', {'prompts': []});
    await connectFuture;

    final registeredCategories = <String, ToolCategory>{};
    manager.registerAllTools((tool) => registeredCategories[tool.name] = tool.category);

    expect(registeredCategories['mcp__playwright__browser_navigate'], ToolCategory.browser);
    expect(registeredCategories['mcp__playwright__browser_take_screenshot'], ToolCategory.browser);
  });
}
