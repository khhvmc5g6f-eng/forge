# Tools

## The pipeline

```
MODEL -> TOOL REQUEST -> POLICY ENGINE -> PERMISSION -> EXECUTOR -> RESULT -> MODEL
```

`ToolGateway.invoke()` (`lib/core/tools/tool.dart`) is the concrete implementation:

1. Look up the registered `Tool` by name.
2. `Tool.describeInvocation(arguments)` builds a `ToolInvocation` — a pure, side-effect-free
   description (category, target path, command risk if applicable) — **before** any
   execution.
3. `PolicyEngine.decide(invocation)` returns `allow` / `ask` / `deny`.
4. On `ask`, the gateway's `onApprovalPrompt` callback (wired to a UI dialog or CLI y/n
   prompt) is invoked; no callback means `ask` is treated as `deny` (fail closed).
5. On `allow`, `Tool.execute(arguments)` runs and returns `UntrustedContent`.
6. Every invocation — allowed, asked, or denied — is appended to `ToolGateway.auditLog`
   (the Diagnostics panel's data source), whether it succeeded or threw.

## Built-in tool categories and tools

| Category | Tools implemented | File |
|---|---|---|
| Filesystem | `list_directory`, `search_files`, `search_code`, `read_file`, `read_range`, `read_multiple_files`, `create_file`, `patch_file`, `rename_file`, `delete_file`, `compare_files` | `lib/core/tools/filesystem_tools.dart` |
| Terminal | `run_terminal_command` | `lib/core/tools/terminal_tool.dart` |
| Git | `git_status`, `git_diff`, `git_log`, `git_branches`, `git_stage`, `git_commit` | `lib/core/git/git_tools.dart` |
| MCP | one bridged tool per server-reported tool, named `mcp__<server>__<tool>` | `lib/core/mcp/mcp_manager.dart` |
| Browser | every `browser_*` tool the Playwright MCP server reports (navigate, click, type, screenshot, accessibility snapshot, console messages, network requests, ...) — bridged the same way as any MCP tool, but re-tagged `ToolCategory.browser` (Control Test Device permission) instead of the generic MCP category | `lib/core/browser/playwright_mcp.dart`, `lib/core/mcp/mcp_manager.dart` |
| Device | `list_devices`, `install_app`, `launch_app`, `device_logs`, `device_screenshot` — real `adb`/`xcrun simctl` process wrappers | `lib/core/devices/device_tools.dart` |
| Computer | `list_accessible_elements`, `click_element`, `click_at`, `computer_type_text`, `computer_press_key`, `capture_screen` — gated through a `ComputerControlSession` with real PAUSE/STOP/EMERGENCY STOP semantics; the underlying macOS driver is a documented stub (see `DEVELOPMENT.md`) | `lib/core/computer/computer_control_tools.dart` |

Database and build/test-specific tool categories are defined in `ToolCategory`
(`lib/core/tools/tool_category.dart`) and have permission-level mappings already wired in
`PolicyEngine`, but no concrete `Tool` implementations exist yet — see `DEVELOPMENT.md`.

## `patch_file`: anchored, verified edits

Per RESEARCH_FINDINGS.md's adoption of Aider's diff-format pattern, `patch_file` does not
accept a full-file rewrite. It takes `find`/`replace` strings and requires the `find` text
to match **exactly once** in the target file — zero matches or an ambiguous multiple match
both fail with a clear error rather than guessing, so a patch either applies exactly as
intended or doesn't apply at all.

## Terminal execution and classification

`TerminalTool` classifies every command via `CommandClassifier` before execution and
records a `CommandExecutionRecord` (command, agent, working directory, start time, output,
exit code, duration) into its `history` — this is the Terminal panel's data source, and
nothing about a terminal invocation is ever hidden, per the brief. See `SECURITY.md` for
the classification rules and the destructive/privileged always-`ask` guarantee.

## Registering a new tool

Implement `Tool` (`lib/core/tools/tool.dart`): `name`, `category`, `description`,
`parametersSchema` (JSON Schema, surfaced to the model as a `ToolSpec`),
`describeInvocation()`, and `execute()`. Call `gateway.register(MyTool(...))`. No change to
`ToolGateway`, `PolicyEngine`, or the agent runtime is required.
