# Forge engine API as consumed by the Flutter app

The Flutter app (Mac, iPhone, iPad, Android) is a **client** of the TypeScript Forge engine
(`/Volumes/Mac Laptop/Forge`, package `@forge/control-plane`, `sdk/packages/forge`). It does not run a control plane of its
own. This file lists exactly which engine surface the client uses, what it assumes, and what is **missing in the engine**
and therefore not implemented in the app (the app shows these as unavailable; it never fakes the data).

Client code: `lib/core/forge_engine/` (`engine_client.dart`, `engine_connection.dart`, `engine_models.dart`,
`live_flow.dart`, `engine_graph.dart`). UI: `lib/ui/engine/`.

## 1. Transport and pairing

* The gateway (`ForgeGateway`, `gateway.ts`) listens on **loopback only** (`127.0.0.1:8765` by default). A phone, or another
  computer, cannot reach it until it is exposed through an https tunnel or reverse proxy (Tailscale Serve, Cloudflare tunnel,
  Caddy, ...). The app works with any address you can reach: `http://127.0.0.1:8765` (same machine / iOS simulator),
  `http://10.0.2.2:8765` (Android emulator), or `https://...`.
* **Pairing string**: `forge://<host>[:port]?token=<bearer>&name=<label>[&tls=1]`. Plain `http(s)://host:port` and bare
  `host:port` are accepted too. Default port 8765 (443 for `https://` without a port). The app has manual entry and paste;
  there is no camera/QR scanner yet.
* **Cleartext**: bearer tokens and new API keys must not cross a network unencrypted. The app warns for `http://` to any
  non-loopback host, and **refuses to send a new provider key** over it (`EngineErrorKind.insecureTransport`). iOS
  (`NSAllowsLocalNetworking`) and Android (`network_security_config`) only allow cleartext to local addresses in any case.
* The app stores the **address in shared preferences** and the **token only in the platform secure store**
  (`flutter_secure_storage`: Keychain on macOS/iOS, Keystore-backed on Android). If the secure store refuses the write the token is
  kept in memory for the session and the UI says so.

## 2. Authentication

The client sends `Authorization: Bearer <token>` on **every** request (state, events, actions) whenever a token is set. The
token is the engine's per-install gateway token (`cp.auth`, `gateway-auth.ts`).

| Surface | Engine behaviour | Client behaviour |
|---|---|---|
| `/forge/state`, `/forge/events`, `/forge/health`, `/v1/*` | loopback callers need no token; any other client must present it | status `unauthorized` on 401/403, **no retry loop**, message "re-pair with a valid token"; token never appears in error text |
| `/forge/api/*` (management API) | **always** needs the token, even on loopback; loopback peers only; 401 otherwise; 404 when the engine was not started with `management` | actions are disabled with the reason ("needs the bearer token" / "rejected the token" / "read-only engine") |

## 3. Read API that exists today

| Route | Used for | Notes |
|---|---|---|
| `GET /forge/state` | everything on the dashboard, vault, circuits, usage, alerts | JSON `ControlPlaneState` (`runtime.ts`): `now, providers[], keys[], active[], circuits[], totals, totalsAllTime, lastEventSeq, guard[], routing{policy,ladder,stats,recentDecisions}, notifications{unread,recent}, diagnostics, analytics, availability[], config`. The client polls every 5 s (2 s when the event stream is down) and also refreshes (throttled to 1.5 s) after state-changing events. |
| `GET /forge/events` | Live Flow, Neural Lab network, refresh triggers | SSE, one `data: <ForgeEvent JSON>` frame per event (`events.ts`). Client sends `last-event-id: <last seq>`; the engine replays up to 100 events after it. |
| `GET /forge/health` | liveness | `{ ok, keys }` |

Facts the client relies on (verified in `gateway.ts`/`dashboard.ts`/`events.ts`):

* `state.keys[]` carries masked display (`masked`), `enabled`, `priority`, key `circuit` snapshot (`id` = `providerId/keyId`),
  `capacity` (limits with source + status), `health` (score is `null` without data), `last15m`, `p50LatencyMs`, `p95LatencyMs`.
* `state.circuits[]` lists only circuits that are **not closed or have tripped**. Provider circuit ids are the provider id,
  key circuit ids `provider/key`, model circuit ids `provider/key/model`. A circuit that is not listed is shown as closed.
* `lastEventSeq` going **backwards** means the engine restarted; the client resets its event log and sequence.
* The client treats events older than 2 minutes (SSE replay of the buffer on connect) as history and never animates them.
* Active calls (`state.active[]`) are the reconcile source: an in-flight request the engine no longer lists after 15 s is dropped.
* Event data used: `MODEL_REQUEST_STARTED{modelId}`, `KEY_SELECTED{why,step}`+target, `MODEL_FIRST_TOKEN{ttftMs}`,
  `MODEL_TOKEN_USAGE{tokens}`, `MODEL_REQUEST_COMPLETE{latencyMs}`, `MODEL_REQUEST_FAILED{reason|kind}`,
  `FAILOVER{from,toKey,kind,status}`, `CIRCUIT_STATE_CHANGED{level,id,to}`, `TOOL_STARTED|COMPLETE|FAILED{tool}` with
  correlation `requestId, agentId, sessionId, taskId, toolCallId`.

## 4. Action API: the engine's management API (`/forge/api/*`)

Implemented in the engine by `control-api.ts` / `control-ops.ts`; enabled only when the host starts the control plane with
`createControlPlane({ management: {} })`. The Dart client (`EngineClient`) uses exactly these routes:

| Action id (UI gate) | Route | Body | Response |
|---|---|---|---|
| (capability probe) | `GET /forge/api/budget` | - | 200 = mounted and token accepted, 404 = read-only engine, 401/403 = token missing/wrong |
| `key.add` | `POST /forge/api/keys` | `{providerId, name, secret, priority?}` | 201 masked `KeyDisplay` (`id`, `masked`, ...), never the secret. Unknown provider: 404 `forge_unknown_provider` |
| `key.test` | `POST /forge/api/keys/{id}/test` | `{modelId?}` | `ApiTestResult` (`status`: pass/fail/skipped/unsupported/rate_limited, `test: true`); real provider call |
| `key.update` (enable/disable only) | `POST /forge/api/keys/{id}/enabled` | `{enabled}` | `{ok}` |
| `key.remove` | `DELETE /forge/api/keys/{id}` | - | `{ok}`; unknown key 404 `forge_unknown_key` |
| `circuit.action` | `POST /forge/api/circuits` | `{level: provider\|key\|model, providerId, keyId?, modelId?, action: disable\|enable\|reset\|probe}` | `{ok, detail?}`; missing `keyId`/`modelId` is a 400 |

Errors are `{ "error": { "type", "message" } }` (messages redacted by the engine). A 404 with a `type` other than
`forge_not_found` is a **refusal** (`EngineErrorKind.rejected`), not "API missing". The client refuses to send `key.add`
over cleartext HTTP to a non-loopback host.

**Not in the engine API (controls stay disabled in the app, with these reasons)**

| UI control | Why it is disabled |
|---|---|
| key priority edit | no route (`key.priority`) |
| provider enable/disable switch | `PUT /forge/api/providers` needs a full provider definition, which `/forge/state` does not carry (`provider.update`) |
| acknowledge alert / acknowledge all | no route (`alert.ack`) |
| resume runaway guard | no route (`guard.resume`) |

## 4a. Where each thing lives in the app (Settings & Connections)

The Control Centre (`lib/ui/engine/`) is **operational only**: dashboard, circuits (start/stop/probe a running thing),
usage, alerts, live flow, network. It never edits configuration and never shows a credential; it deep-links to
Settings & Connections (`lib/ui/settings/`): *Engine connection* (address, token), *Provider credentials* (the engine vault
screen: add/test/enable/remove keys; legacy-key migration), *Notifications*, and on desktop *On-device agent*.
Provider credentials are entered **only** in the engine vault.

**Legacy keys.** Earlier builds saved provider keys (`nvidia_nim_api_key`, `anthropic_api_key`, `openai_api_key`, plus the
refs the Dart model providers read) in the app's own secure storage (Keychain service `app.forge.secrets`). The input is
gone. Existing copies stay readable (the on-device model providers still read them) and are flagged "legacy — move to engine".
"Move to engine vault" (user-confirmed per key): sends the key once over `POST /forge/api/keys`, waits for the engine to
return the new key id **and** for a fresh `/forge/state` to list it, then overwrites and deletes the old copy and verifies it
is gone. Engine unreachable / read-only / token rejected / cleartext link / refusal / unconfirmed: nothing is deleted.

## 5. Gaps: needed from the engine, not built, not faked in the app

| Missing in the engine | Effect in the app |
|---|---|
| Management API routes for priority, provider enable, alert ack, guard resume | those controls are disabled with the reason (section 4) |
| Management API mounted by default (`forge-gateway.ts` does not pass `management`) | an engine started with that script is read-only for this app |
| Budget rules in `/forge/state` (BudgetGuard rules, 402 hard stops) and an API to edit them | Usage page states that budgets cannot be shown or edited yet; only per-key capacity limits are shown |
| History/export API (`AnalyticsStore.queryUsage/summarize/export`), latency/error/cache analytics views | no historical charts or export; only the 15-minute and all-time totals in state |
| Logs search (`logger.search`) and trace/timeline (correlated events) over HTTP | no log viewer or trace page |
| Model discovery run + API test suite over HTTP (`discovery.discoverKey`, `tests.runSuite`) | availability matrix is shown read-only (it is in state); cannot run discovery |
| Limits/cost editor for keys (`vault.setLimits/setCost/setModels`) | limits are shown, not editable |
| Routing policy/ladder editor (`router.setDefaultPolicy/setLadder`), `forge.yaml` reload | shown read-only |
| `TASK_*` / `AGENT_*` events (not emitted by anything yet) | the Neural Lab only shows agents that appear in `correlation.agentId` of real requests; other traffic is a single "Unattributed client" node; there is no tasks page driven by the engine |
| SSE heartbeat (`: ping` comments) and `id:` lines | the client cannot tell "idle" from "dead TCP" on the stream except via the 5 s state poll; it falls back to polling status honestly. It uses the event `seq` as the resume id |
| Replay buffer beyond 100 events per connect | after a long outage the client reports `missedEvents` rather than pretending continuity |
| Remote-reachable listener (non-loopback bind) | a tunnel/proxy is required for phones |
| Push notifications | alerts only notify while the app is running and connected (local notifications) |

## 6. Dart control plane (TD-004): what is deprecated and what is not

See `CONTROL_PLANE.md`, "Migration to the engine". Short version: `CircuitBreaker`, `CircuitBreakerRegistry`,
`CredentialVault`, `CapabilityRouter` are deprecated and no longer used by any UI; `SupervisorEngine`, `TaskGraph` and
`ModelTier` stay because the engine has no equivalent (supervisor/worker task-graph dispatch, directive 24-26).

## 7. Verification

**2026-10-03 (read API).** Client unit/integration tests run against a fake HTTP + SSE engine (`test/forge_engine/fake_engine.dart`);
the opt-in live test parsed the real `/forge/state`, opened the real SSE stream, drove a real `/v1/chat/completions` request and saw
the real `MODEL_REQUEST_STARTED -> KEY_SELECTED -> FAILED` events; the iOS Simulator build connected over `127.0.0.1:8791`.

**2026-10-04 (management API, Settings & Connections).** `test/forge_engine/live_engine_test.dart` ran green against the real
TypeScript engine started from `/Volumes/Mac Laptop/Forge` with `createControlPlane({ management: { token } })` (memory secret
store, an Ollama provider and an OpenAI-shaped provider pointing at a dead port):

* no token and a wrong token: `capabilities()` reports `authRejected`, `removeKey` raises `unauthorized`;
* `addKey` returns the masked key (the secret is not in the response, not in `/forge/state`), `/forge/state` lists it;
* an unknown provider is a refusal with the engine's message; an unknown key is a refusal;
* enable/disable a key, key test (real call, `test: true`), circuit disable/enable on the provider, reset on the key,
  and the engine's 400 for a key circuit without `keyId`;
* legacy-key migration end to end (engine confirms, fresh state lists the key, old copy deleted), then `removeKey`;
* against the stock `scripts/forge-gateway.ts` (no `management`): `capabilities()` is read-only and the management test skips.

Run it: start an engine with `management: { token }`, then
`FORGE_LIVE_ENGINE=http://127.0.0.1:PORT FORGE_LIVE_TOKEN=... FORGE_LIVE_MANAGEMENT=1 flutter test test/forge_engine/live_engine_test.dart`.

**Engine behaviour found while verifying (not changed here, engine repo is out of scope):** an idle engine sends **no** SSE
response headers on `GET /forge/events` until its first event (there is no initial `: open` comment). The client therefore
cannot see "stream open" until something happens; until then it shows "polling only" and its open attempt times out after 8 s
and is retried. Recommended engine fix: write `: open\n\n` (and a periodic `: ping`) immediately.

Not verified: physical devices, a non-loopback tunnel (the management API is loopback-only on the engine side, so a phone
cannot use the action API without engine changes), notification permission prompts, the Android emulator.
