# Model providers

## Abstraction

`ModelProvider` (`lib/core/models/model_provider.dart`) is the single interface every
backend implements: `listModels()`, `chat()`, `streamChat()`, `healthCheck()`. Nothing
above this layer is allowed to special-case a specific provider.

`OpenAiCompatibleProvider` (`lib/core/models/providers/openai_compatible_provider.dart`) is
the base adapter for the `/v1/chat/completions` + `/v1/models` wire format shared by NVIDIA
NIM, OpenAI, Ollama, LM Studio, and any self-hosted OpenAI-compatible endpoint (vLLM,
text-generation-webui, ...). It handles request/response translation, streaming (SSE line
parsing), retry with exponential backoff on 429/5xx, and timeout handling once, so each
concrete provider subclass only supplies its base URL, auth header, and any
capability-inference quirks:

| Provider | File | Notes |
|---|---|---|
| NVIDIA NIM | `providers/nvidia_nim_provider.dart` | `https://integrate.api.nvidia.com/v1/` by default; also usable against a self-hosted NIM microservice base URL |
| OpenAI | `providers/local_providers.dart` (`OpenAiProvider`) | Official API |
| Ollama | `providers/local_providers.dart` (`OllamaProvider`) | `http://localhost:11434/v1/`, always `isFree`/`isLocal` |
| LM Studio | `providers/local_providers.dart` (`LmStudioProvider`) | `http://localhost:1234/v1/` |
| Generic | `providers/local_providers.dart` (`GenericOpenAiCompatibleProvider`) | Any other OpenAI-compatible endpoint, fully user-configured |
| Anthropic | `providers/anthropic_provider.dart` | Not OpenAI-wire-compatible (distinct Messages API, `tool_use`/`tool_result` blocks, no models-list endpoint) — its own adapter, used both as an ordinary provider and as the Claude Final Reviewer |

## Capabilities and the registry

`ModelCapabilities` (`lib/core/models/model_capabilities.dart`) declares what a model
*should* support (tool calling, vision, reasoning effort, context window, free/local
status). `ModelRegistry` additionally tracks `ModelPerformanceRecord` — empirically observed
coding/tool/reasoning reliability, latency, success/failure/rate-limit counts, last-tested
timestamp — the data backing the brief's NVIDIA Model Registry table and the future Model
Arena's output. `ModelRouter` (`model_router.dart`) ranks candidates by this data, not by
capability declaration alone; a model with zero recorded runs is preferred over one with
*proven* low reliability, but ranks below anything demonstrated reliable.

## Routing policy

`RoutingPolicy` (`model_router.dart`): `auto` (strongest suitable **free** model first,
escalate only if none qualifies — the brief's default policy), `freeOnly`, `localOnly`,
`nvidiaOnly`, `manual` (an explicit `ModelId`). Selection also respects
`TaskRequirements.minContextWindowTokens`/`requiresToolCalling`/`requiresVision` per
`TaskCategory` (`task_classifier.dart`).

## Secrets

See `SECURITY.md#secrets`. In short: `SecretsStore` is the only place an API key is
read/written; never store one in a config file, Git, or a `ProviderConfig` (which only ever
carries a `apiKeySecretRef` lookup key, never the value itself).

## Built-in local runtime (no separate Ollama installation)

Forge does not require Ollama — or any local inference server — to be installed as a
separate system. `lib/core/local_models/ollama_runtime.dart` implements a **built-in,
Forge-owned runtime**:

- the server binary is provisioned under `~/.forge/runtime/ollama/bin`, downloaded from
  the official distribution zip on first use (or extracted from a staged copy under
  `~/.forge/runtime/ollama/downloads/`);
- pulled models live under `~/.forge/runtime/ollama/models` — never `~/.ollama`, so
  nothing leaks outside Forge's managed directory;
- the `serve` process is spawned and supervised as a Forge child (`OLLAMA_HOST` and
  `OLLAMA_MODELS` are pinned to Forge-owned values), with a health-checked start,
  graceful-then-forced stop, and the phase machine
  `notInstalled → installing → stopped → starting → running/failed`. A server Forge
  did not spawn is never silently adopted: if a separately installed Ollama already
  answers on the configured port, the managed runtime takes the next free one;
- the existing `OllamaProvider` adapter simply points at the runtime's OpenAI-compatible
  endpoint (the live `openAiBaseUrl`), so the Model Router, circuit breakers and
  Model Arena treat local models like any other provider — free and local for routing.

The Models panel exposes Start/Stop and a pull field against this runtime. Every OS or
network operation is an injected seam, so the unit tests
(`test/core/local_models/ollama_runtime_test.dart`) exercise the full lifecycle without
spawning processes or opening sockets. End-to-end against the real binary:

    dart run tool/verify_runtime.dart
    dart run tool/verify_runtime.dart --pull qwen2.5-coder:7b

