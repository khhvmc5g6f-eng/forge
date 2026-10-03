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

## 2. Authentication (PENDING in the engine)

The client sends `Authorization: Bearer <token>` on **every** request (state, events, actions) whenever a token is set.
The gateway does not check it yet (another agent is adding it). Expected contract, which the client already handles:

| Case | Engine answer | Client behaviour |
|---|---|---|
| missing / wrong / expired token | `401` (or `403`) | status `unauthorized`, **no retry loop**, message "re-pair with a valid token"; token never appears in error text |
| engine without auth | `200` | works without a token (local dev) |

Until auth ships, anything that can reach the port can read `/forge/state`. Do not expose the port without a proxy that
enforces the token.

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

## 4. Action API: PROPOSED (does not exist in the engine yet)

The engine has **no mutation endpoints over HTTP**. Vault, circuit and alert operations exist only as in-process calls
(`cp.vault.*`, `cp.board.*`, `cp.alerts.*`, `cp.guard.*`) and as Tauri sidecar commands in
`apps/examples/desktop-app/sidecar/forge-*-commands.ts` (`forge_vault_add_key`, `forge_circuit_action`, `forge_cc_ack`,
`forge_cc_guard_resume`, ...). So a remote client cannot manage anything until the gateway exposes them.

The client is written against the following contract, discovered at runtime so a read-only engine degrades cleanly:

```
GET /forge/api/v1/capabilities
  -> 200 { "version": "1", "actions": ["key.add","key.test","key.update","key.remove","circuit.action","alert.ack","guard.resume"] }
  -> 404 = read-only engine (the app disables every mutation and says "This engine is read-only")
```

All action routes need the bearer token, accept/return JSON, answer `{ "ok": boolean, "message": string, ... }`, return
`4xx { "error": { "message" } }` for refusals and must **never echo a secret**.

| Action id | Route | Body | Maps to |
|---|---|---|---|
| `key.add` | `POST /forge/api/v1/vault/keys` | `{providerId, name, secret, priority?}` | `forge_vault_add_key` / `vault.addKey` (secret goes straight to the OS credential store; response has the masked view only) |
| `key.test` | `POST /forge/api/v1/vault/keys/{keyId}/test` | `{}` | `forge_vault_test_key` (real provider call; flagged `test: true`) |
| `key.update` | `PATCH /forge/api/v1/vault/keys/{keyId}` | `{enabled?, priority?}` | `vault.setEnabled`, `vault.setPriority` |
| `key.update` | `PATCH /forge/api/v1/vault/providers/{providerId}` | `{enabled}` | `forge_vault_upsert_provider` (enabled only) |
| `key.remove` | `DELETE /forge/api/v1/vault/keys/{keyId}` | - | `forge_vault_remove_key` |
| `circuit.action` | `POST /forge/api/v1/circuits/action` | `{level: provider|key|model, id, action: disable|enable|reset|probe}` | `forge_circuit_action` (`board.manual`) |
| `alert.ack` | `POST /forge/api/v1/alerts/ack` | `{id}` or `{all: true}` | `alerts.acknowledge(All)` |
| `guard.resume` | `POST /forge/api/v1/guard/resume` | `{scope}` | `guard.resume(scope)` |

Note `key.update` covers priority, enable/disable of keys and providers; the client gates the buttons per action id.

## 5. Gaps: needed from the engine, not built, not faked in the app

| Missing in the engine | Effect in the app |
|---|---|
| Bearer-token check (in progress elsewhere) | token is sent and stored; local engines accept without one |
| Action API of section 4 | Vault/Circuits/Alerts screens are read-only; buttons disabled with the reason |
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
