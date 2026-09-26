# Multi-Provider Control Plane

This document covers the extension added on top of the original FORGE build: the
federated, circuit-breaker-protected, tiered supervisor/worker architecture described in
the Control Plane specification. It extends — does not replace — `PROVIDERS.md`,
`AGENTS.md`, and `NVIDIA.md`.

## LiteLLM evaluation (architecture decision record)

The spec asks Forge to "investigate using LiteLLM as FORGE's underlying provider
gateway/router" and "prefer proven LiteLLM functionality where appropriate rather than
rebuilding reliable provider plumbing unnecessarily."

**Finding: LiteLLM is a Python library/proxy server; Forge is a Dart/Flutter
application.** There is no Dart binding for LiteLLM, and LiteLLM is not published as a
language-agnostic wire protocol of its own — its "unified provider API" *is* the Python
SDK surface (or its optional local HTTP proxy server, which re-exposes an
OpenAI-compatible `/chat/completions` endpoint). Concretely, that leaves two honest
integration shapes, and this document picks between them rather than pretending a direct
library import is possible:

1. **Run `litellm --config ...` as a local sidecar process** and have Forge's existing
   `OpenAiCompatibleProvider` (`lib/core/models/providers/openai_compatible_provider.dart`)
   point at it as just another OpenAI-compatible base URL. This would hand LiteLLM's own
   retry/fallback/budget/virtual-key logic the job Forge's `CircuitBreaker`/
   `CapabilityRouter`/`CredentialVault` already do natively in-process.
2. **Do not integrate LiteLLM**, and let Forge's own control plane (this extension) own
   retries, fallbacks, cooldowns, load balancing, rate-limit awareness, budgets, cost
   tracking, and multi-credential management directly in Dart.

**Decision: (2), reject direct LiteLLM integration; adopt its architecture as a checklist,
not as a dependency.**

Reasons:

- **A Python sidecar process is a new failure domain and deployment burden** for a
  standalone macOS desktop app — it means bundling or requiring a Python runtime, managing
  a subprocess's lifecycle, and adding a network hop (Forge → LiteLLM proxy → provider)
  for every model call, for functionality Forge already has natively.
- **The spec's own layering puts Forge's routing logic *above* the provider gateway**
  ("FORGE's semantic task routing and hierarchical orchestration remain above LiteLLM" /
  "LiteLLM handles infrastructure reliability. FORGE handles intelligence and
  orchestration.") Circuit breaking, tiering, and credential management are exactly
  *infrastructure reliability* concerns by the spec's own framing — duplicating them in
  both LiteLLM (Python, sidecar) and Forge (Dart, in-process) would mean two
  sources of truth for the same state (is this provider healthy right now?), which is
  strictly worse than one.
- **Forge's implementations are complete and tested without it**: `CircuitBreaker`
  (`lib/core/control_plane/circuit_breaker.dart`) already implements the
  CLOSED/DEGRADED/OPEN/HALF_OPEN/RECOVERING state machine LiteLLM's own cooldown/fallback
  logic would otherwise provide; `CapabilityRouter` already does tier- and
  capability-preserving failover; `CredentialVault` already does multi-key management.
  There is no remaining "reliable provider plumbing" left for LiteLLM to save Forge from
  rebuilding — it was built once, natively, and is exercised by 36+ passing tests
  (`test/core/control_plane/`).
- **What LiteLLM is genuinely good at — normalising many providers' wire formats behind
  one API — is a solved problem for Forge already**: every provider added under this
  extension (Groq, Cerebras, OpenRouter, Z.AI, Google) is OpenAI-wire-compatible and slots
  into the existing `OpenAiCompatibleProvider` base with a ~30-line subclass (see
  `lib/core/models/providers/additional_providers.dart`), live-verified against OpenRouter
  (458 real models, no key required) and Groq (a real 401 without a key) during
  development.

**What this means going forward**: if a future provider is *not* OpenAI-wire-compatible
and building a bespoke adapter is expensive, LiteLLM (as a sidecar) becomes worth
revisiting for *that one provider's request translation only* — not as Forge's general
gateway. No such provider has been needed yet: even Google Gemini and Anthropic (the two
non-OpenAI-native wire formats in scope) either expose an official OpenAI-compatibility
endpoint (Google) or already have a first-class native adapter (Anthropic, also needed
independently for Claude Final Review).

## What's implemented (`lib/core/control_plane/`)

| File | Spec requirement | Tests |
|---|---|---|
| `circuit_breaker.dart` | Per-provider/model/tool/MCP-server circuit with CLOSED→DEGRADED→OPEN→HALF_OPEN→RECOVERING→CLOSED, infra-vs-quality-vs-generated-code failure differentiation | `test/core/control_plane/circuit_breaker_test.dart` (13 tests) |
| `circuit_breaker_registry.dart` | One registry for every circuit id, health-ranked candidate lists | same file |
| `model_tier.dart` | Tiers S/A/B/C/Local, not permanently bound to named models; recomputed from empirical `ModelPerformanceRecord`; manual pin overrides auto-recompute | `test/core/control_plane/capability_router_test.dart` |
| `capability_router.dart` | Tier- and capability-preserving selection/failover, skipping OPEN circuits at both provider and model granularity | same file (7 tests) |
| `credential_vault.dart` | Multi-key-per-provider (`NVIDIA_KEY_1`/`NVIDIA_KEY_2` style), explicit (never automatic) active-slot switching — the rate-limit-evasion boundary from the spec | `test/core/control_plane/credential_vault_test.dart` (6 tests) |
| `task_graph.dart` | `TaskContract` (the full structured contract: objective/scope/allowed files/tools/permissions/budgets/tier/return format), dependency-aware `TaskGraph`, `WorkerResult` parsing (RESULT/EVIDENCE/CONFIDENCE/UNCERTAINTIES/NEXT ACTION) | `test/core/control_plane/supervisor_engine_test.dart` |
| `supervisor_engine.dart` | Dispatches ready nodes with a concurrency limit, fails a node over to the next healthy same-tier candidate on infra failure, flags (not fails) low-confidence results for escalation, reconciles conflicting worker results without averaging | same file (9 tests) |

Plus, wired into the pre-existing engine rather than duplicating it:

- `ModelRouter.isCircuitAvailable` (`lib/core/models/model_router.dart`) — an optional hook
  so the plain single-agent routing path also excludes OPEN circuits, without
  `core/models/` taking a dependency on `core/control_plane/` (avoiding an import cycle;
  the hook is a bare closure type, wired in `lib/app/forge_providers.dart`).
- `AgentOrchestrator.onModelOutcome` (`lib/core/agents/orchestrator.dart`) — an optional
  callback so a plain (non-task-graph) orchestrator run also feeds circuit-breaker state.
- Five new provider adapters (`lib/core/models/providers/additional_providers.dart`):
  Groq, Cerebras, OpenRouter, Z.AI, Google — all thin `OpenAiCompatibleProvider`
  subclasses, base URLs verified current as of this writing.
- The Control Centre UI (`lib/ui/panels/control_centre_panel.dart`) — live provider/model
  circuit states with manual Test/Open/Close/Reset controls and tier pinning, plus
  Credential Vault management (add/remove/set-active-slot).

## What's a documented gap, not a fake

- **Google's Gemini-native (non-OpenAI-compat) API** is not implemented — the official
  OpenAI-compatibility endpoint is used instead (see the `GoogleProvider` doc comment);
  this covers `/chat/completions` but not every Gemini-specific parameter.
- **Automatic rolling quality-based demotion** (the spec's "HEALTHY → QUALITY DEGRADED →
  reduce allocation → benchmark → recover or demote" loop) currently happens via
  `TierRegistry.recomputeFromRegistry`, which must be called (on a schedule, or after N
  tasks) — it is not yet wired to an automatic timer/trigger.
- **Cost/quota tracking** (RPM/TPM/daily/monthly quotas, a cost dashboard) is not yet
  built; `TokenUsage` accounting exists (`lib/core/models/chat_types.dart`) but nothing
  aggregates it into budgets or the "MAXIMUM COST"/"MAXIMUM TOKENS" controls yet.
- **The Model Arena's actual benchmark-task runner** (sending controlled tasks to score
  models) is still the gap noted in `NVIDIA.md` — the scoring *data model* it would feed
  (`ModelPerformanceRecord`, `TierRegistry`) is complete and tested.
- **A live, end-to-end demonstration of the full failover chain against real paid
  providers** (NVIDIA → Cerebras → Groq → Z.AI → OpenRouter → local, per the spec's worked
  example) requires funded API keys for at least two of those providers, which this
  development environment does not have; the failover *logic* is verified with real HTTP
  behaviour (OpenRouter's public listing, Groq's real 401) at the provider-adapter layer
  and with deterministic fakes at the orchestration layer (`supervisor_engine_test.dart`).
