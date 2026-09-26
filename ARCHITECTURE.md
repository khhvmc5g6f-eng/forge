# Architecture

## Layers

```
lib/
  core/            # Platform-independent engine. No Flutter imports. Shared by GUI + CLI.
    models/        # ModelProvider abstraction, adapters, registry, router, task classifier
    tools/         # Tool interface, ToolGateway, PolicyEngine, command classifier, fs/terminal tools
    agents/        # AgentRole/AgentDefinition, AgentRuntime (shared ReAct loop), Orchestrator
    tasks/         # Task, TaskManager, TaskStore (disk-persisted, resumable)
    git/           # GitService, CheckpointManager, BranchIsolation, git-backed Tools
    mcp/           # McpTransport (stdio), McpClient (JSON-RPC), McpManager, tool bridging
    review/        # Reviewer abstraction, ReviewPackage, ReviewCycleRunner
    security/      # SecretsStore, UntrustedContent
    project/       # ProjectManager — recent projects, multi-project switching
    context/       # RepoIndexer/RepoIndex/RepoSearch — symbol/import indexing, ranked search
    memory/        # MemoryStore/MemoryEntry — persistent per-project knowledge
    devices/       # DeviceManager + Adb/IosSimulator DeviceProviders, device Tools
    browser/       # Playwright MCP server config/bridge (browser automation via MCP)
    computer/      # ComputerControlSession (PAUSE/STOP/EMERGENCY STOP), driver + tools
  app/             # Riverpod providers wiring core services together for the GUI
  ui/              # Flutter widgets only — shell, panels. Never touches core internals directly
                    # except through app/forge_providers.dart.
  cli/             # forge_cli.dart — the CommandRunner-based CLI, calling only into core/**
bin/
  forge.dart       # Thin executable entry point for the CLI
```

The rule that keeps the GUI and CLI from diverging: **everything in `core/` is
Flutter-independent Dart**, and both `lib/ui/` (via `lib/app/forge_providers.dart`) and
`lib/cli/forge_cli.dart` are consumers of it, never re-implementations. There is exactly
one `AgentRuntime`, one `PolicyEngine`, one `ModelRouter` — the brief's requirement that
"the GUI and CLI must use the SAME backend agent engine" is structural, not a convention
someone has to remember.

## Data flow (the brief's pipeline, as implemented)

```
User request
  -> TaskManager.createTask()                (lib/core/tasks/task_manager.dart)
  -> AgentOrchestrator.spawn()/.spawnParallel() (lib/core/agents/orchestrator.dart)
       -> ModelRouter.selectModel(TaskCategory)  (lib/core/models/model_router.dart)
       -> AgentRuntime.run()                     (lib/core/agents/agent_runtime.dart)
            -> ModelProvider.chat()               (lib/core/models/providers/*)
            -> ToolGateway.invoke()                (lib/core/tools/tool.dart)
                 -> PolicyEngine.decide()           (lib/core/tools/policy_engine.dart)
                 -> Tool.execute() -> UntrustedContent
  -> ReviewCycleRunner.run() with a *different* Reviewer than the author model
                                                (lib/core/review/reviewer.dart)
  -> CheckpointManager / GitService for commit/branch/PR
                                                (lib/core/git/*)
```

Every arrow above is a real method call in this codebase today, exercised by the test
suite (`test/`) — this is not an aspirational diagram.

## Why a shared `AgentRuntime` instead of 19 agent classes

`AgentRole` (`lib/core/agents/agent_role.dart`) enumerates every specialist role from the
brief (Orchestrator, Planning, Repository, Coding, Debugging, Architecture, Testing,
Performance, Security, Database, API, UI, Browser, Computer-Use, Git, Documentation,
Dependency, Review, Final Review Preparation). Each is an `AgentDefinition` — a system
prompt, an allowed tool-category set, a default `TaskCategory` for model routing — not a
subclass. `AgentRuntime` (`lib/core/agents/agent_runtime.dart`) is the single ReAct loop
(call model → run any tool calls → feed results back → repeat) parameterised by whichever
`AgentDefinition` the Orchestrator hands it. Adding a new role is a configuration entry,
not new agent code — directly per RESEARCH_FINDINGS.md's adaptation of Roo Code's
declarative "modes."

## Naming

"Forge" is the working project name. Nothing in `lib/core/` references the name "Forge"
except the CLI's own `CommandRunner('forge', ...)` string and this documentation set — a
rebrand touches `lib/app.dart` (the `MaterialApp.title`), `pubspec.yaml`'s `name:`, and the
CLI's display name, and nothing else.

## Extensibility (plugin points)

Per the brief's plugin-interface requirement, these are the seams designed for external
extension without core changes:

- `ModelProvider` (`lib/core/models/model_provider.dart`) — new providers implement this
  interface; most concretely subclass `OpenAiCompatibleProvider`
  (`lib/core/models/providers/openai_compatible_provider.dart`) if they speak the
  OpenAI-compatible wire format.
- `Tool` (`lib/core/tools/tool.dart`) — new capabilities register on a `ToolGateway`.
- `AgentDefinition` (`lib/core/agents/agent_role.dart`) — new roles are data, not code.
- `Reviewer` (`lib/core/review/reviewer.dart`) — any model-backed or future non-model
  reviewer implements this to sit in the review pipeline.
- `McpTransport` (`lib/core/mcp/mcp_transport.dart`) — additional MCP transports (HTTP/SSE)
  implement this alongside the existing `StdioMcpTransport`.
- `SecretsStore` (`lib/core/security/secrets_store.dart`) — platform secret backends.

None of these require touching the Orchestrator, the Policy Engine, or the UI shell to add
a new instance.
