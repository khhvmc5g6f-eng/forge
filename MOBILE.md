# Forge on iPhone, Android and Mac (remote client)

Forge's engine is the Cline codebase (our `Cline-Enhanced` repo: Cline + circuit breaker/failover, budgets, autonomy levels, role agents, analytics, repo intelligence). Coding agents need a real filesystem and shell, so they run on your Mac. This app is the phone/tablet/desktop **client**: it drives the engine over the hub's WebSocket (`apps/cline-hub`, `/browser`).

## What is in `lib/core/cline_hub/`
- `protocol/` typed messages, endpoint rules (Origin/Host/roomSecret auth, cleartext detection), reconnecting client
- `state/` chat reducer, session controller, autonomy presets, voice controller
- `services/` keystore-backed settings, on-device speech (STT) + system TTS
- `ui/` connect, chat (streaming, tool cards, approvals), sessions, hub, settings

Phones (iOS/Android) open straight into this workspace. Desktop keeps the existing Forge shell and adds a **Cline Hub** section.

## Running it
1. On the Mac: `cd apps/cline-hub && bun run start` (add `HOST=0.0.0.0 PUBLIC_URL=... ROOM_SECRET=...` to reach it from a phone).
2. `flutter run -d <device>` in this repo; enter the hub address (+ room secret if set).
3. Simulator/emulator reach the host at `127.0.0.1` (iOS) / `10.0.2.2` (Android).

Opt-in live test against a real hub: `FORGE_LIVE_HUB=http://127.0.0.1:8787 flutter test test/cline_hub/live_hub_test.dart`.

## Security notes
- Cleartext `http/ws` is only allowed for local addresses (iOS `NSAllowsLocalNetworking`; Android network-security-config allows `localhost`, `127.0.0.1`, `10.0.2.2` only). Reaching a Mac over a real network needs `https/wss` (a TLS tunnel such as Tailscale Serve or a Cloudflare tunnel); the app warns when you enter a non-local `http` address.
- The room secret is stored only in the platform keystore; the hub address is in ordinary preferences. If the keystore rejects the write (e.g. unsigned simulator builds) the app still connects and tells you.
- Voice never approves tool calls; approvals always need a tap.

## Verified (2026-09-29)
Flutter analyze clean; 177 tests pass (Forge's existing suite + 31 for the client). Debug builds: Android APK, macOS app, iOS simulator app. Live: Dart client <-> real Cline hub <-> local Ollama model streamed a reply; the iPhone 17 Pro simulator UI connected to the hub and completed a chat turn with the user message, streamed reply and token usage displayed.

## Not verified / not built
Physical devices; Android emulator run; iPad layout; push/background notifications; on-device speech recognition (needs a device or simulator with dictation - the plumbing and permissions are in place, but it was not exercised); per-tool approval policies (the hub `send` config only exposes `autoApproveTools`, so the app has four autonomy levels, not the CLI's five); bundle id is still the Flutter placeholder `com.example.forge`.
