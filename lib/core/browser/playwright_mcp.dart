import '../mcp/mcp_manager.dart';

/// Forge's browser automation is implemented by bridging to the official
/// Playwright MCP server (`@playwright/mcp` on npm) through the existing
/// [McpClient]/[McpManager] infrastructure (`lib/core/mcp/`), rather than a
/// bespoke Chrome DevTools Protocol client — directly per
/// RESEARCH_FINDINGS.md ("Prefer mature frameworks such as Playwright") and
/// the brief's requirement that MCP be a first-class subsystem. Every
/// `browser_*` tool the server reports (navigate, click, type, screenshot,
/// console messages, network requests, accessibility snapshot, ...) is
/// bridged as an ordinary Forge [Tool] via [McpManager.registerAllTools],
/// tagged [ToolCategory.browser] so it resolves through the Policy Engine at
/// [PermissionLevel.controlTestDevice] like any other browser/device action
/// (see `mcp_manager.dart`'s category override).
///
/// This has been connected live during development: `npx -y
/// @playwright/mcp@latest` started under Forge's own [StdioMcpTransport] and
/// reported 25 tools including `browser_navigate`, `browser_click`,
/// `browser_type`, `browser_take_screenshot`, `browser_snapshot`
/// (accessibility tree — preferred over screenshots for taking actions, per
/// the brief's "prefer semantic APIs before coordinate-based clicking"),
/// `browser_console_messages`, and `browser_network_requests`/
/// `browser_network_request`. See `DEVELOPMENT.md` for the exact command
/// used to reproduce this.
McpServerConfig playwrightMcpServerConfig({
  String id = 'playwright',
  String name = 'Playwright',
  List<String> extraArgs = const [],
  bool headless = true,
}) {
  return McpServerConfig(
    id: id,
    name: name,
    command: 'npx',
    args: [
      '-y',
      '@playwright/mcp@latest',
      if (headless) '--headless',
      ...extraArgs,
    ],
    category: McpServerCategory.playwright,
    // Untrusted by default like any MCP server, per SECURITY.md/MCP.md —
    // being the officially maintained Playwright package does not exempt it
    // from the same trust model every other server gets.
    trusted: false,
  );
}
