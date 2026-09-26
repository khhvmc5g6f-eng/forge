# MCP (Model Context Protocol)

## Implementation

`lib/core/mcp/` implements MCP as a first-class, dynamically-discovered subsystem:

- `McpTransport` (`mcp_transport.dart`) — transport abstraction. `StdioMcpTransport` spawns
  the server process and speaks newline-delimited JSON-RPC 2.0 over its stdin/stdout, per
  the MCP stdio transport spec (not LSP-style `Content-Length` framing). `FakeMcpTransport`
  is provided for tests. An HTTP/SSE transport implements the same interface when needed —
  nothing above this layer is transport-specific.
- `McpClient` (`mcp_client.dart`) — the JSON-RPC client: `initialize` handshake,
  `tools/list`, `tools/call`, `resources/list`, `resources/read`, `prompts/list`. Every
  capability is discovered at connect time; nothing about a server's tool set is
  hard-coded.
- `McpManager` (`mcp_manager.dart`) — add / remove / enable / disable / test servers, and
  `McpBridgeTool`, which wraps one discovered MCP tool as a Forge `Tool` so it goes through
  the exact same `ToolGateway`/`PolicyEngine`/`UntrustedContent` pipeline as a built-in
  tool.

## Trust model

`McpServerConfig.trusted` defaults to **`false`**. Per the brief — "Do not automatically
trust newly installed MCP servers" — a new server's tool results are `UntrustedContent`
with `ContentSource.mcpResource`, identical treatment to any other tool result; `trusted`
is surfaced in the MCP panel purely so the user can see which servers they've deliberately
vetted. It does not currently relax any Policy Engine check — the security boundary is the
same regardless of the flag. Widening the sandbox for a "trusted" server would be a
deliberate, separate design decision, not implicit in this flag.

## Configuring servers

Via the UI's MCP panel (`lib/ui/panels/mcp_panel.dart`), or via the CLI, which reads
`.forge/mcp.json` in the project root:

```json
[
  {
    "id": "filesystem",
    "name": "Filesystem MCP",
    "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/allowed/dir"],
    "trusted": false
  }
]
```

`forge mcp list` connects to each configured server, discovers its tools, and prints
connection state.

## Browser automation is an MCP integration, not a separate subsystem

Forge does not implement its own Chrome DevTools Protocol client. Browser automation
(`lib/core/browser/`) is the official Playwright MCP server (`@playwright/mcp` on npm)
connected through this exact `McpClient`/`McpManager` machinery, with its tools re-tagged
`ToolCategory.browser` instead of the generic `ToolCategory.mcp` (see
`McpManager.registerAllTools()`). This was connected live during development — `npx -y
@playwright/mcp@latest` under a real `StdioMcpTransport` reported 25 tools including
`browser_navigate`, `browser_click`, `browser_snapshot` (the accessibility-tree
capture the brief prefers over raw screenshots for taking actions), `browser_console_messages`,
and `browser_network_requests`. See `TOOLS.md` and `DEVELOPMENT.md` for the reproduction
steps and `playwright_mcp.dart` for the config helper.

## Catalogue

The brief calls for a catalogue UI grouping known-good MCP servers by category (GitHub,
Git, Filesystem, Browser, Playwright, Databases, Documentation, Cloud, Design, Testing,
Developer Tools). `McpServerCategory` (`mcp_manager.dart`) defines these categories; a
curated, in-app catalogue view (rather than requiring the user to hand-type a command) is
tracked for a later milestone — today, adding a server means supplying its command/args
directly, same as any MCP-compatible client.
