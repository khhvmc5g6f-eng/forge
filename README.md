# Forge

Forge is a standalone, provider-independent AI software-engineering workstation for macOS
(with a portable core that also runs on Linux/Windows for development). It combines the
strongest architectural patterns from Claude Code, Codex CLI, Cline, Roo Code, Continue,
Aider, NVIDIA NIM, and MCP into one observable, recoverable, extensible development
environment — see [`RESEARCH_FINDINGS.md`](RESEARCH_FINDINGS.md) for the prior-art survey
behind these choices.

Forge is architected so NVIDIA-hosted and local models do the bulk of software-engineering
work, with Claude available as an optional, pluggable **final reviewer** rather than a
requirement for every operation. "Forge" is a working name, chosen to be easy to rebrand
later (see [`ARCHITECTURE.md`](ARCHITECTURE.md#naming)).

## What's actually built vs. planned

This repository is implemented milestone-by-milestone (see [`DEVELOPMENT.md`](DEVELOPMENT.md)).
**Genuinely working today**, with passing automated tests and, where applicable, live
verification against real external services:

- Provider-agnostic model layer: NVIDIA NIM, OpenAI, Ollama, LM Studio, Anthropic adapters
  (`lib/core/models/`) — `forge models` performs a real, live call to NVIDIA's public
  `/v1/models` endpoint and lists the current catalogue.
- Model Registry + Router with a Model Arena-ready performance-tracking data model
  (`lib/core/models/model_registry.dart`, `model_router.dart`).
- Tool Gateway + deterministic Policy Engine with the full SAFE→PRIVILEGED command
  classification and 0–8 permission ladder (`lib/core/tools/`).
- Filesystem, terminal, and Git tools wired through the gateway (`lib/core/tools/`,
  `lib/core/git/`).
- Git integration + checkpoint/branch-isolation system (`lib/core/git/`).
- Agent Orchestrator with bounded, depth/concurrency/timeout-limited subagent spawning,
  and 19 specialist agent roles sharing one `AgentRuntime` (`lib/core/agents/`).
- Task Manager with disk-persisted, resumable tasks (`lib/core/tasks/`).
- MCP client/manager over the stdio JSON-RPC transport, with tool bridging into the
  Tool Gateway (`lib/core/mcp/`).
- Reviewer abstraction + Review Package builder + bounded rework cycle
  (`lib/core/review/`).
- A working desktop shell (sidebar/centre/bottom-panel) wired to the real backend
  (`lib/ui/`), and a CLI (`forge`/`aiwork`) sharing the identical backend
  (`lib/cli/forge_cli.dart`, `bin/forge.dart`).
- Repository Indexer + ranked search (`lib/core/context/`) — real regex-based
  symbol/import extraction across Dart/JS/TS/Python, wired into the Projects panel.
- Persistent per-project Memory (`lib/core/memory/`) — architecture decisions, known
  issues, prior fixes, stored in `.forge/memory.json`, with a real search/record UI.
- Multi-project switching (`lib/core/project/`) — a global recent-projects list; opening
  a project fully re-derives every other provider (Git, Tasks, Memory, Tool Gateway) from
  its root, verified via both the UI's Projects panel and `forge open`.
- Device Manager (`lib/core/devices/`) — real `adb`/`xcrun simctl` process wrappers for
  Android and iOS Simulator discovery/install/launch/logs/screenshot, degrading correctly
  to "no devices" (not fabricated data) when neither SDK is installed, as in this
  container.
- Browser automation (`lib/core/browser/`) — bridges the official Playwright MCP server
  (`npx @playwright/mcp`) through the existing MCP client/manager; **live-verified during
  development**: connecting discovered the real 25-tool `browser_*` surface (navigate,
  click, type, screenshot, accessibility snapshot, console messages, network requests).
- Computer-use session controls (`lib/core/computer/`) — real, tested PAUSE/STOP/EMERGENCY
  STOP semantics and Policy Engine gating; the macOS Accessibility driver itself is a
  documented stub (see `DEVELOPMENT.md`) since it needs a native platform channel this
  Linux container cannot build or run.
- Multi-Provider Control Plane (`lib/core/control_plane/`, see `CONTROL_PLANE.md`) — a
  genuine CLOSED/DEGRADED/OPEN/HALF_OPEN/RECOVERING circuit breaker per provider and per
  model, a capability-tier system (S/A/B/C/Local) with tier- and requirement-preserving
  failover, a multi-credential-per-provider vault, five additional live provider adapters
  (Groq, Cerebras, OpenRouter, Z.AI, Google — OpenRouter's public 458-model listing and
  Groq's real auth-failure both verified live), and a Task Graph/Supervisor engine that
  dispatches dependency-aware parallel worker nodes, fails a node over to the next healthy
  same-tier model on infrastructure failure, and reconciles conflicting worker results
  without averaging — all wired into a live Control Centre UI panel.

**What's still a documented stub, not faked data**: the macOS Accessibility driver behind
computer-use (needs a real macOS host + Xcode to implement and verify — see
`DEVELOPMENT.md`), and the macOS Keychain-backed `SecretsStore` (same constraint). Every
other "not yet built" item from earlier drafts of this README has since been implemented —
see the list above.

## Running it

```bash
flutter pub get
flutter test                 # full test suite
dart run bin/forge.dart --help
```

The desktop shell (`flutter run -d macos`, once building on an actual macOS host with
Xcode) opens on the current working directory as its project root. See
[`DEVELOPMENT.md`](DEVELOPMENT.md) for platform-specific build notes, including what does
and does not work outside macOS.

## Documentation map

| Doc | Covers |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | System layers, data flow, naming/rebrand strategy |
| [`SECURITY.md`](SECURITY.md) | Threat model, sandboxing, untrusted-content handling |
| [`AGENTS.md`](AGENTS.md) | Agent roles, orchestration, subagent budgets |
| [`TOOLS.md`](TOOLS.md) | Tool Gateway, Policy Engine, command classification |
| [`MCP.md`](MCP.md) | MCP client/manager, trust model |
| [`PROVIDERS.md`](PROVIDERS.md) | Model provider abstraction, secrets |
| [`NVIDIA.md`](NVIDIA.md) | NVIDIA NIM integration specifics |
| [`CONTROL_PLANE.md`](CONTROL_PLANE.md) | Multi-provider circuit breakers, tiers, Task Graph/Supervisor engine, LiteLLM decision |
| [`CLINE_AUDIT.md`](CLINE_AUDIT.md) | What was reused/adapted/rejected from Cline before building the Control Plane |
| [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md) | Independent review + Claude Final Review pipeline |
| [`CLI.md`](CLI.md) | `forge`/`aiwork` command reference |
| [`PERMISSIONS.md`](PERMISSIONS.md) | Operating modes, permission ladder, mappings |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | Milestones, build instructions, what's stubbed |
| [`TESTING.md`](TESTING.md) | Test strategy, how to run, acceptance-suite mapping |
| [`RECOVERY.md`](RECOVERY.md) | Task persistence, resume-after-restart, checkpoints |
