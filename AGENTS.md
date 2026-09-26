# Agents

## Roles, not classes

`lib/core/agents/agent_role.dart` defines `AgentRole` (19 values, matching the brief) and
`defaultAgentDefinitions`, a `Map<AgentRole, AgentDefinition>`. Each `AgentDefinition`
carries:

- `systemPrompt` — the role's instructions
- `allowedToolCategories` — a hint used to scope which tools are offered to the model
  (`AgentRuntime._availableTools()`); the actual security boundary is still the
  `PolicyEngine`, not this list
- `defaultTaskCategory` — which `TaskCategory` the `ModelRouter` assumes when no more
  specific category is supplied
- `maxIterations` — the per-agent ReAct loop cap (default 25)

A user or plugin can register additional `AgentDefinition`s at runtime by passing a custom
map into `AgentOrchestrator(definitions: ...)` — no subclassing required.

## The shared runtime

`AgentRuntime.run()` (`lib/core/agents/agent_runtime.dart`) is the one ReAct loop every role
executes:

1. Send the system prompt + task prompt + available tools to the selected model.
2. If the model requests tool calls, execute each via `ToolGateway.invoke()`, wrap the
   result as `UntrustedContent`, and feed it back as a tool-result message.
3. Repeat until the model stops requesting tools or `maxIterations` is hit (raises
   `AgentRuntimeException` — this is the loop's own runaway guard, independent of the
   Orchestrator's subagent budget).

Every model call and tool call emits an `AgentEvent` via the optional `onEvent` sink —
this is the transparent event-stream surface from the brief ("Show actions and evidence.
Do not expose private model chain-of-thought.") — `AgentEvent.toString()` never includes
raw model reasoning, only the action taken and its result summary.

## Orchestration and subagent budgets

`AgentOrchestrator` (`lib/core/agents/orchestrator.dart`) implements
`spawn()`/`spawnParallel()`, bounded by `SubagentBudget`:

| Limit | Default | Purpose |
|---|---|---|
| `maxDepth` | 3 | A subagent spawned by a subagent can spawn further subagents up to this many levels — prevents unbounded recursive delegation |
| `maxConcurrency` | 4 | `spawnParallel` batches requests to this many simultaneous agents |
| `maxTotalAgents` | 20 | Hard cap on agents spawned for one orchestration run |
| `perAgentTimeout` | 10 min | Each agent's `AgentRuntime.run()` is wrapped in `.timeout()` |

Exceeding any of these throws `SubagentBudgetExceededException` rather than silently
queuing — callers (the Orchestrator's caller, or a UI) decide how to surface that. Calling
`AgentOrchestrator.cancel()` makes every subsequent `spawn()` fail immediately, for a
cooperative-cancellation "stop this task" action.

Example from the brief — "Investigate why Cockpit Core consumes excessive CPU" —
decomposes into:

```dart
final reports = await orchestrator.spawnParallel([
  SubagentRequest(role: AgentRole.debugging, prompt: 'Trace Flutter rebuilds ...'),
  SubagentRequest(role: AgentRole.repository, prompt: 'Review recent commits touching Cockpit Core ...'),
  SubagentRequest(role: AgentRole.performance, prompt: 'Profile CPU/frame time ...'),
]);
```

`orchestrator.totalSpawned` and the `onEvent` stream give the Orchestrator (and the UI's
Diagnostics/Agents panels) full visibility into what ran, at what depth, on which model.
