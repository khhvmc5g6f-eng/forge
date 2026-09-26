# NVIDIA NIM integration

NVIDIA NIM is a first-class provider (`lib/core/models/providers/nvidia_nim_provider.dart`),
not an afterthought — this is by design, per the brief's directive that Forge should
reduce dependence on frontier-model calls by using NVIDIA-hosted and local models for the
bulk of software-engineering work.

## Verified behaviour

`NvidiaNimProvider` extends `OpenAiCompatibleProvider` pointed at
`https://integrate.api.nvidia.com/v1/`. This has been exercised live against the real
endpoint from this development environment:

- `forge models` (`lib/cli/forge_cli.dart`) performs an **unauthenticated** `GET /v1/models`
  call and receives NVIDIA's full current catalogue (~80 models at the time of writing) —
  confirming model discovery does not assume a fixed, hard-coded model list, and reflects
  "current NVIDIA APIs rather than assuming one model forever" as the brief requires.
- `forge ask "..."` without a configured API key produces a real `401` from NVIDIA's
  `/v1/chat/completions` ("Header of type `authorization` was missing") — confirming the
  auth path (`Authorization: Bearer <key>` from `SecretsStore`) is real, not mocked.

Both behaviours are reproducible: run `dart run bin/forge.dart models` and
`dart run bin/forge.dart ask "test"` from this repository.

## Capability table

`NvidiaNimProvider._knownModels` is a curated starting point for coding-agentic-capable
models (tool calling, context window, free status) — e.g.
`nvidia/llama-3.1-nemotron-70b-instruct`, `qwen/qwen2.5-coder-32b-instruct`,
`deepseek-ai/deepseek-r1`, `meta/llama-3.3-70b-instruct`. This is deliberately not the
source of truth: `ModelRegistry`'s empirical `ModelPerformanceRecord` (see `PROVIDERS.md`)
overrides these with observed reliability, and any model absent from the curated map still
gets conservative default capabilities rather than being excluded from discovery.

## Configuration

Set the `nvidia_nim_api_key` secret via the Settings panel or directly through
`SecretsStore.write('nvidia_nim_api_key', '<key>')`. A self-hosted NIM microservice is
supported by constructing `NvidiaNimProvider(baseUrl: Uri.parse('http://<host>:<port>/v1/'))`
— the adapter makes no assumption that NVIDIA's own cloud endpoint is the only valid target.

## Model Arena (design, not yet implemented)

The brief calls for controlled-task benchmarking (code understanding, generation,
debugging, tool calling, terminal operation, architectural reasoning, test generation,
visual interpretation, long-context repository work) feeding
`ModelRegistry.recordArenaScores()`. The data model (`ModelPerformanceRecord`) and the
recording API already exist and are exercised by `test/core/models/model_router_test.dart`;
the benchmark-task runner itself is tracked for a later milestone (see `DEVELOPMENT.md`).
