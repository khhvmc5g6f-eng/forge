# Research Findings — Prior Art Survey for Forge

Forge is an autonomous AI software-engineering workstation. Before settling its
architecture, this document surveys the agent loop, tool-calling, context and
security patterns used by existing coding agents and records which ones Forge
adopts, adapts, or rejects, and why. No source code from any of these systems
is reused; only architectural patterns are studied.

Columns: **System | Useful Feature | Architectural Pattern | Relevance to Forge | Implement/Adapt/Reject | Reason**

## Agent loop & orchestration

| System | Useful Feature | Architectural Pattern | Relevance | Decision | Reason |
|---|---|---|---|---|---|
| Claude Code | Single-agent ReAct loop with an explicit todo list surfaced to the user | Plan → tool call → observe → update plan, looped until done, with a visible task list as shared state between model and user | High — Forge's Task Manager needs the same "visible plan" property for trust | Adapt | We generalise the todo list into a persisted `Task` state machine (PLAN/ACT/VERIFY steps) that survives restarts, rather than an in-memory list tied to one conversation |
| Claude Code | Subagent dispatch for isolated, bounded investigations | Parent spawns a subagent with a narrow prompt and tool subset; subagent returns a report, not raw transcript | High — matches the Orchestrator → Specialist Agent pattern in the brief | Implement | Directly maps to Forge's `AgentOrchestrator.spawnSubagent()` with depth/concurrency/timeout caps |
| Codex CLI | Sandboxed exec-first loop: every action is a shell command, patches are just `apply_patch` calls | Minimal tool surface (shell + patch) rather than dozens of bespoke tools | Medium — simplicity is attractive but under-serves structured operations like MCP or Git | Adapt | Forge keeps a small *core* tool surface (files, terminal, git) and treats everything else (browser, devices, MCP) as pluggable tool categories behind the same gateway, so the model still sees one calling convention |
| Cline | Explicit approval gate before every file write or command, rendered as a diff/command card in the UI | Human-in-the-loop checkpoint per action rather than per session | High — directly required by the brief's permission ladder | Implement | Forge's `PolicyEngine` returns `allow / ask / deny` per tool call; UI renders the same card pattern |
| Cline / Roo Code | "Modes" (Plan/Act, Architect/Code/Debug) that change which tools and system prompt are active | A finite set of operating modes swaps behaviour without swapping the underlying model | High — maps directly to Forge's CHAT/ASSIST/AGENT/AUTONOMOUS/REVIEW modes | Implement | Modes become a first-class enum gating the permission ladder (0–8) rather than a prompt-only convention |
| Roo Code | Custom "modes" are user-definable YAML, not hard-coded | Declarative agent role definition (name, prompt, allowed tools, model preference) | Medium | Adapt | Forge's specialist agents (Coding, Debugging, Security, …) are configuration records over one shared `AgentRuntime`, not 20 separate classes, per the brief |
| Continue | IDE-embedded context providers (`@file`, `@codebase`, `@diff`, `@terminal`) that let the user or model pull scoped context on demand | Context is assembled from named, composable providers rather than one big repo dump | High — avoids the "send the whole repo" anti-pattern the brief explicitly forbids | Implement | Forge's Repository Intelligence layer exposes the same idea as `ContextProvider` implementations (symbol, diff, test, git-history) selected by the Planner |
| Aider | Repo map: a token-budgeted, ranked summary of the whole codebase (via ctags/tree-sitter) sent alongside the diff-format edits | Cheap structural context beats full-file context for large repos | High | Implement | Forge's Repository Indexer builds a similar ranked symbol map; the Model Router uses it to decide how much raw source vs. summary to include per task |
| Aider | Diff-format edits ("SEARCH/REPLACE" blocks) applied deterministically outside the model | Edits are structured and machine-verified before touching disk | High | Implement | Forge's `patch_file` tool requires a structured patch object (file, anchor, replacement), not free-form file rewrites, so the Policy Engine can validate it pre-apply |
| Aider | Auto-commit after every accepted edit, with the prompt/response in the commit message | Fine-grained, reversible history | Medium | Adapt | Forge checkpoints (Git commit + metadata record) before *and* after each task step rather than every micro-edit, to keep history legible, per the brief's Checkpoint model |

## Model abstraction & tool calling

| System | Useful Feature | Architectural Pattern | Relevance | Decision | Reason |
|---|---|---|---|---|---|
| NVIDIA NIM | OpenAI-compatible `/v1/chat/completions` with `tools`/`tool_choice`, streaming SSE, and a model catalogue endpoint | Same wire format as OpenAI, Ollama, LM Studio, vLLM | High — lets one HTTP client serve most providers | Implement | Forge's `OpenAiCompatibleProvider` is the base class; NVIDIA NIM, Ollama, LM Studio, OpenAI, and any future OpenAI-compatible endpoint subclass it with only base-URL/auth differences |
| NVIDIA NIM | Per-model capability metadata (context length, function-calling support) surfaced via `/v1/models` | Machine-readable capability discovery instead of hard-coded lists | High | Implement | Feeds the Model Registry directly; unknown models default to conservative capabilities until probed |
| Anthropic API | Distinct message/tool-use schema (`tool_use`/`tool_result` content blocks), prompt caching, extended thinking | Not wire-compatible with OpenAI | High | Implement | Separate `AnthropicProvider` adapter behind the same `ModelProvider` interface; used both as a normal provider and as the Final Reviewer |
| MCP (Model Context Protocol) | JSON-RPC 2.0 over stdio/HTTP with `tools/list`, `resources/list`, `prompts/list`, capability negotiation | Transport-agnostic, dynamically discovered tool/resource surface | High — required by the brief | Implement | Forge's `McpClient` implements the base JSON-RPC envelope once; stdio first (covers filesystem/git/github MCP servers), HTTP/SSE transport added behind the same interface |
| MCP servers (filesystem, GitHub, Playwright) | Each server owns a narrow, auditable capability | Principle of least privilege per integration | High | Implement | Forge never grants a model raw shell access to reach these capabilities when an MCP server exists; the Tool Gateway treats MCP tools as just another tool category subject to the same policy checks |
| Cline/Roo Code | Provider-agnostic "any model, any tool-calling style" including simulated tool-calling via prompted JSON for models without native function calling | Fallback tool-calling parser for weaker/local models | Medium | Adapt | Forge's `ToolCallParser` supports native function-calling when available and falls back to a constrained JSON-in-text protocol for local models that lack it, since the brief requires local-model support |

## Terminal, filesystem & Git

| System | Useful Feature | Architectural Pattern | Relevance | Decision | Reason |
|---|---|---|---|---|---|
| Claude Code | Command allow/deny lists with pattern matching, "ask" as a distinct middle state | Three-way policy decision instead of binary allow/deny | High | Implement | Forge's `CommandClassifier` + `PolicyEngine` exactly mirrors this three-way outcome, extended with the brief's SAFE/READ/BUILD/TEST/INSTALL/NETWORK/MODIFY/DESTRUCTIVE/PRIVILEGED taxonomy |
| Codex CLI | OS-level sandboxing (seatbelt/landlock) for shell execution, not just a prompt-level policy | Defence in depth: policy engine *and* OS sandbox | High | Adapt | macOS target: sandbox agent-initiated processes via `sandbox-exec` profiles scoped to the project + temp workspace directories, so a prompt-injection cannot escape the Policy Engine even via a novel command string |
| Aider / Claude Code | Git as the undo mechanism — every state is a commit | Git commit = checkpoint | High | Implement | Forge's Checkpoint store is a thin wrapper recording commit SHA + task + changed files, never a bespoke snapshot format |
| Claude Code | Worktrees/branches for isolated agent work | Autonomous work happens off the user's current branch | High | Implement | Forge creates `ai/task/<id>-<slug>` branches (or git worktrees when the user is mid-work on the main branch) before any autonomous edit |

## Security & untrusted content

| System | Useful Feature | Architectural Pattern | Relevance | Decision | Reason |
|---|---|---|---|---|---|
| Claude Code | Explicit framing of tool output/web content as untrusted, separate from user instructions | Instruction/data channel separation | High | Implement | Forge wraps all tool results, MCP resource content, and terminal stdout in an `UntrustedContent` envelope the Orchestrator cannot promote to an instruction without a Policy Engine decision |
| Cline/Roo Code | Deny-by-default for destructive or privileged commands regardless of "autonomous" mode | Autonomy raises convenience, never raises the security ceiling | High | Implement | `sudo`, `rm -rf`, force-push etc. always require explicit human confirmation even in AUTONOMOUS MODE, matching Permission tiers 6–8 in the brief |

## Rejected patterns

| System | Feature | Reason for rejection |
|---|---|---|
| Various "computer-use" demos | Pure vision+coordinate clicking as the primary UI automation method | Brittle and slow versus semantic accessibility APIs; Forge only falls back to vision when no accessibility tree is available, per the brief |
| Some agent frameworks | Unbounded recursive subagent spawning | Directly causes runaway cost/loops; the brief mandates max depth/concurrency, so this pattern is rejected outright |
| Several CLI agents | Sending the full repository as context on every request | Token-expensive and defeats long-session use; rejected in favour of Aider-style repo maps + Continue-style scoped context providers |

## Summary of architectural decisions this produces

1. One `ModelProvider` interface, OpenAI-compatible base adapter reused for NVIDIA NIM/Ollama/LM Studio/OpenAI, a separate Anthropic adapter, both behind a `ModelRegistry` with empirically tracked scores (the brief's Model Arena).
2. A single `AgentRuntime` with configuration-driven roles instead of N bespoke agent classes; an `Orchestrator` that spawns bounded, depth/concurrency/timeout-limited subagents.
3. A `ToolGateway` in front of every capability (filesystem, terminal, git, MCP, browser, device) enforcing a deterministic `PolicyEngine` — the LLM proposes, the engine decides.
4. Git-native checkpointing and branch isolation; no bespoke snapshot format.
5. MCP as a first-class, dynamically-discovered tool source, not a hard-coded integration.
6. Context assembly via ranked repository indexing + scoped context providers, never whole-repo dumps.
7. Author/reviewer separation is structural: the model that authored a patch is never the sole reviewer; Claude is wired in as a pluggable `Reviewer` behind the same abstraction as any other provider.
