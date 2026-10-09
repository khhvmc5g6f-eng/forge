# Neural Observatory — Real-Time AI Diagnostics, Performance Analytics and Autonomous Optimisation

The Observatory is Forge's telemetry subsystem: one shared
`ObservatoryService` beneath the whole application (per the design brief's
"most important design decision"), instrumenting sessions, model requests,
agent runs, tool calls, network traffic and host resources, and feeding
five analysis surfaces plus a gated self-improvement engine.

This document is the completion report for the implementation. It follows
the same honesty rules as the code: every claim below is either
test-enforced or explicitly listed as not built.

## A. Architecture

```
lib/core/observability/          # Flutter-free pure Dart (ARCHITECTURE.md layering rule)
  telemetry.dart                  # ObsSpan (OTel-style trace/span/parent ids),
                                  #   MeasurementQuality, redactAttributes, AgentTelemetry
  rolling_stats.dart              # RollingStats (min/max/mean/median/P50/P90/P95/P99,
                                  #   moving average, EWMA, trend) + bounded MetricSeries
  token_rate.dart                 # StreamRateAnalyzer (TTFT, stalls, peak) + whole-request rate
  cost_model.dart                 # CostCalculator — configured pricing only, never guessed
  context_window.dart             # utilisation + OLS exhaustion prediction with confidence
  anomaly.dart                    # robust MAD z-score spikes, pre-shift-baseline level shifts,
                                  #   AlertCenter (acknowledge/suppress/resolve, dedup)
  health.dart                     # 8-component HealthIndex — coverage, never fake passes
  model_scorecard.dart            # live per-model stats + composite EfficiencyScore
  execution_trace.dart            # execution graph, critical path, fan-out, cost breakdown
  telemetry_store.dart            # bounded/batched JSONL persistence with retention rotation
  resource_sampler.dart           # `ps`-based CPU/RSS (measured); GPU explicitly unavailable
  counting_http_client.dart       # passive byte counting around any http.Client
  observatory_service.dart        # the shared service: sessions, spans, scorecards, alerts
  observatory_queries.dart       # session comparison, task cost breakdown, health assembly
  self_improvement.dart           # gated OptimisationJob lifecycle + protected scopes

lib/ui/panels/observatory/        # the workspace: Overview / Sessions / Models / Trace / Network
  (agent_runtime / orchestrator / # instrumentation is one optional AgentTelemetry hook,
   supervisor_engine)             #   default null — pre-Observatory behaviour preserved
```

Instrumentation flows: `ObservatoryService.telemetryFor(sessionId,
taskId)` returns a stamping adapter; `AgentRuntime` (and via it the
`AgentOrchestrator` and `SupervisorEngine`) reports agent start/finish,
per-request model latency + provider-reported tokens, and per-tool
durations. Network bytes flow passively through `CountingHttpClient`,
which wraps every provider adapter's HTTP client at the app layer.
Provider/key health is adapted from `CircuitBreakerRegistry` through a
masked `ProviderStatusRow` boundary (credentials never cross it).

## B. Repository changes

New: `lib/core/observability/` (16 files), `lib/ui/panels/observatory/`
(5 files), `test/core/observability/` (12 files, 62 tests).
Modified: `lib/core/agents/agent_runtime.dart`, `orchestrator.dart`,
`lib/core/control_plane/supervisor_engine.dart` (optional telemetry hook,
default null), `lib/app/forge_providers.dart` (service + counting client
wiring), `lib/ui/shell/{forge_shell,sidebar_section}.dart` (Observatory
section), `lib/cli/forge_cli.dart` (`forge observatory` command),
`README.md` (doc map).

## C. Features — built vs not

Fully operational and test-enforced: session lifecycle and stats;
correlated spans (session→agent→model/tool) with critical path and
fan-out; rolling percentiles and trends; whole-request tokens/sec;
TTFT/stall analysis for streamed chunks; cost accounting from configured
pricing (free-tier $0, unknown = unavailable); context-window ETA with
confidence; MAD anomaly detection + alert lifecycle; 8-component health
index with coverage; per-model scorecards + efficiency score with
published methodology and insufficient-data flags; session intelligence
comparison; per-task time/money breakdown; passive network byte counting;
`ps`-based CPU/RSS sampling (GPU honestly unavailable); bounded/batched
JSONL persistence with rotation and redaction; `forge observatory` CLI;
the full self-improvement lifecycle state machine (all four modes,
protected-scope authorisation, test/benchmark/review gates, rollback).

Not built (deliberately, with reasons): streaming UI (the runtime uses
non-streaming `chat`, so TTFT/token-rate are wired at the analyzer level
but nothing feeds them live yet — no streaming conversation surface
exists in the app); active network diagnostic mode (passive only);
dashboard builder/drag-drop layouts (fixed five-tab workspace); replay
scrubber and OTLP export (the JSONL store is the substrate; OTLP
serialisation is an add-on); anomaly→proposal wiring in the UI (the
engine's `proposeFromAnomaly` is proven by tests; a "propose fix" button
needs the conversation loop, which does not exist yet).

## D. Instrumentation coverage

Measured: model-request latency (Stopwatch in the runtime), tool-call
duration, session duration, provider-request bytes in/out (socket-side
counting), process CPU/RSS (`ps`). Provider-reported: prompt/completion/
cached token counts. Calculated: whole-request tokens/sec, cost from
configured pricing, percentiles, efficiency scores. Estimated: context
exhaustion ETA (OLS, confidence disclosed). Unavailable (never faked):
GPU utilisation, true inter-token speed without streaming, provider
quota balances, cost without configured pricing.

## E. Testing

`flutter test` — 227 tests pass (145 pre-Observatory + 62 observability
+ concurrent-session local-models). Unit coverage: percentiles, TTFT,
stalls, cost math, context ETA, MAD detection (incl. flat-baseline
refusal), health coverage rules, scorecard accumulation, efficiency
normalisation, store rotation/backpressure/redaction, sampler failure
paths. Integration: a real `AgentRuntime` run through a real
`ToolGateway` populates session stats, the execution graph, breakdowns
and persisted JSONL end-to-end. Self-improvement: every gate tested —
observe refusal, investigate stop, test-fail rollback, regression
rollback, review-rejection rollback, protected-scope authorisation,
controlled-autonomy deployment. `dart analyze lib`: no issues.

## F. Performance impact

Recording is in-memory bounded structures plus a queued append; disk I/O
happens on flush (every 64 events or manual), never on the request path.
The one deliberate runtime cost: every provider HTTP response passes
through a counting stream wrapper.

## G. External dependencies

None. Zero new packages — only existing deps (`http`, `uuid`, `path`,
Riverpod) and `dart:io`'s `Process.run`.

## H. Security

Credentials never enter telemetry: `redactAttributes` strips
secret-shaped values at the persistence boundary (type-based so token
*counts* survive), provider keys surface only as masked references, and
the self-improvement engine structurally refuses to modify approval,
audit, security, credential, payment or migration code without explicit
authorisation — enforced by tests, not convention.

## I. Outstanding work

Streaming conversation surface (unblocks live TTFT/token-rate display);
wiring `telemetryFor` into the future chat loop; active network tests;
dashboard builder; replay scrubber; OTLP export; anomaly→proposal wiring
in the UI; multi-key per-provider rows (the vault supports them; the row
adapter currently reports the primary reference).

## J. Operating it

Desktop: the **Observatory** sidebar section (five tabs; samples host
resources every 2s while open; disabled under `flutter test`).
CLI: `forge observatory` prints a summary from persisted telemetry.
Telemetry files: `<project>/.forge/observability/events-*.jsonl`.
Configure pricing via `CostCalculator.configure(...)`; mark models
free/paid via `ObservatoryService.noteModel(...)`.
Self-improvement: construct a `SelfImprovementEngine` with injected
implement/test/benchmark/review/deploy/rollback operations (production
wiring should reuse the Orchestrator, `GitService` branch isolation, the
test runner, and a `Reviewer` that is not the author model), choose the
autonomy mode, then `proposeFromAnomaly` → `advance` per gate.

