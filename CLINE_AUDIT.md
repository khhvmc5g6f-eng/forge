> **CORRECTION (2026-10-03).** This audit was written against marketing copy and is superseded by
> `Forge/FORGE_PROGRAM/01-cline-capability-register.md` (code-verified, upstream 39ff2359f). Wrong claims below:
> multi-agent is *not* marketing-only (team runtime, spawn_agent, subagents, run recovery exist);
> checkpoints are refs in the user's own repo, *not* a shadow git; Cline has 228 providers, not six;
> there is no keychain/keytar credential store; MCP is client-only (tools only); there is no git or browser tool.
> Still correct: no provider failover/circuit breaker, user-directed model switching, Apache-2.0.

# Cline Audit (Control Plane Extension)

Performed live against the current `cline/cline` GitHub repository before building the
Control Plane extension, per the spec's "audit Cline before reimplementation" requirement.

## What Cline actually is, as of this audit

- **License**: Apache 2.0 ("Apache 2.0 © 2026 Cline Bot Inc.") — lawful to draw
  *architectural patterns* from.
- **Stack**: TypeScript/Node.js (Bun package manager), a monorepo (`sdk/`, `apps/cli/`,
  `apps/examples/desktop-app/` on Tauri+Next.js, plus the original VS Code extension).
  Cline has migrated to an SDK-first architecture: `sdk/packages/` contains `@cline/core`,
  `@cline/agents`, `@cline/llms`, `@cline/shared`, with the CLI, VS Code extension, and
  desktop app all consuming the same SDK — the same "one engine, many front ends" principle
  Forge already follows (`ARCHITECTURE.md`).
- **Provider abstraction**: `@cline/llms` — supports Anthropic, OpenAI, Google, AWS
  Bedrock, Mistral, Ollama, and "any OpenAI-compatible" endpoint out of the box.
- **Checkpoints**: a shadow-git-based undo system ("tracked with checkpoints, so you can
  easily undo the agent's work").
- **MCP**: first-class (`cline mcp` server management).
- Multi-agent/"scheduled agents" are mentioned in current Cline marketing copy, but the
  audit found no evidence of a hierarchical supervisor/worker task-graph orchestrator
  comparable to what this spec requires — Cline's agent model is fundamentally
  single-session-at-a-time with tool use, not a decomposition-and-delegation system.

## Component-by-component: reuse, adapt, or reject

| Component | Cline has it? | Decision | Reason |
|---|---|---|---|
| Provider abstraction | Yes (`@cline/llms`) | **Adapt the pattern, not the code** | Forge already has an equivalent (`ModelProvider`/`OpenAiCompatibleProvider`, `lib/core/models/`) in Dart; Cline's is TypeScript and tied to its own SDK's request/response types. Cross-language code reuse isn't feasible here — the *pattern* (one base OpenAI-compatible adapter, thin per-provider subclasses) is what Forge already followed before this audit, independently arriving at the same shape Cline uses. |
| Model registry/metadata | Partial | **Reject direct reuse** | No evidence of Cline exposing a capability-scored registry comparable to `ModelRegistry`/`ModelPerformanceRecord`; Forge's is more specific to this spec's tiering requirement anyway. |
| Provider configuration/credentials | Yes | **Adapt the pattern** | Forge's `SecretsStore`/Credential Vault (this extension) follows the same "never put the raw key in a prompt or log" principle Cline documents; implementation is necessarily platform-specific (macOS Keychain via Dart vs. Node's `keytar`-equivalent). |
| OpenAI-compatible endpoints | Yes | **Already adopted** | Forge's `OpenAiCompatibleProvider` predates this audit and follows the same shape. |
| Model switching | Yes | **Reject as insufficient** | Cline's model switching is user-directed, not the capability-scored, circuit-breaker-aware failover this spec requires — this is exactly the gap the Control Plane extension fills. |
| Token/cost accounting | Yes | **Adapt the pattern** | Forge's `TokenUsage`/cost-dashboard design (see `PROVIDERS.md`) already covers this; no Cline code applicable across languages. |
| Subagents/task orchestration | Marketing claims only | **Reject — build our own** | No hierarchical hardware/task-graph system found; Forge's `AgentOrchestrator` (pre-existing) plus this extension's Task Graph Engine and Supervisor/Worker model go considerably further than anything documented in current Cline. |
| Tools/MCP/terminal/filesystem/Git/checkpoints | Yes | **Already adopted the pattern** | Forge's `ToolGateway`+`PolicyEngine`, `McpClient`, `TerminalTool`, `GitService`/`CheckpointManager` (all pre-existing, see `TOOLS.md`/`MCP.md`/`RECOVERY.md`) follow the same "gateway in front of every capability" and "checkpoint before mutation" shapes Cline documents, arrived at independently and validated against Cline's public description rather than copied.

## Conclusion

No Cline source code is vendored into Forge (different language/runtime makes that
impractical regardless of license). Where Cline's documented architecture confirms a
pattern Forge already uses (provider abstraction, checkpoints, MCP-as-first-class, "one
engine many front ends"), that is noted above as independent convergence, not copying.
Where this spec's hierarchical supervisor/worker/circuit-breaker/multi-provider-failover
requirements go beyond anything Cline currently documents, Forge builds new subsystems
(`lib/core/control_plane/`, this document's sibling additions) rather than assuming Cline
already solves them.
