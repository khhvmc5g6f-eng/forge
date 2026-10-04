# Development

## Building

```bash
flutter pub get
flutter analyze lib bin test    # 0 errors expected (lint infos only)
flutter test                    # 123 tests, all passing as of this writing
dart run bin/forge.dart --help  # CLI, works on any platform with the Dart SDK
```

**Desktop shell**: `flutter run -d macos` requires an actual macOS host with Xcode
installed — this development environment is a Linux container and cannot build, launch, or
screenshot the macOS `.app`. Every other verification in this repository (analyzer, full
test suite including widget tests via Flutter's headless test binding, live CLI runs
against the real NVIDIA NIM API, live MCP/Playwright connection) has been performed
directly; the macOS build step is the one thing that genuinely requires a different
machine to prove. `flutter run -d linux` will build and can be manually smoke-tested on a
Linux desktop with a display server, which exercises the same Dart UI code as macOS minus
the platform channel work still pending (Keychain, native ADB/Xcode tooling).

## Deploying to macOS (run this on an actual Mac, not in this container)

Once this repository is cloned onto a Mac with Xcode and the Flutter SDK installed:

```bash
git clone <this-repo-url> forge && cd forge
flutter config --enable-macos-desktop   # one-time, if not already enabled
flutter pub get
flutter analyze lib bin test            # should report 0 errors
flutter test                            # should report all tests passing
flutter build macos --release           # produces build/macos/Build/Products/Release/forge.app
open build/macos/Build/Products/Release/forge.app
```

For iterative development instead of a release build: `flutter run -d macos` launches a
debug build with hot reload. The CLI builds independently of the Flutter toolchain:
`dart compile exe bin/forge.dart -o forge` produces a standalone `forge` binary (works on
macOS, Linux, or Windows, since `lib/cli/` and `lib/core/` have no Flutter dependency).

First run on macOS needs at least one provider API key in the **engine vault** (Settings & Connections > Provider
credentials, which talks to the engine; the app no longer has its own key inputs) before any model call through the engine
succeeds. The standalone Dart CLI and the on-device model providers still read the legacy `SecretsStore` entries — `forge models`
and the live NVIDIA/OpenRouter listings documented in `NVIDIA.md`/`CONTROL_PLANE.md` work
without a key, but `chat()` calls do not. The macOS Keychain-backed `SecretsStore` and the
Accessibility-API-backed computer-use driver (`lib/core/computer/computer_control_driver.dart`)
are the two integration points that only become real once built on macOS — see
`SECURITY.md#secrets` and this file's Milestone 9 row for what to wire up.

## Milestones (per the master brief) and their status in this repository

| # | Milestone | Status |
|---|---|---|
| 1 | Architecture, repository, secure local backend | Done — this repo, `lib/core/security/` |
| 2 | Desktop shell and project management | Done — shell (`lib/ui/`) + multi-project switching (`lib/core/project/`, `lib/ui/panels/projects_panel.dart`), verified via UI and `forge open` |
| 3 | NVIDIA provider and model router | Done, live-verified (`NVIDIA.md`) |
| 4 | Filesystem and terminal tools | Done (`lib/core/tools/`) |
| 5 | Agent orchestrator | Done (`lib/core/agents/`) |
| 6 | Git/GitHub | Git done (`lib/core/git/`); GitHub API/CLI integration (issues/PRs/CI status) not yet built |
| 7 | MCP | Done for stdio transport (`lib/core/mcp/`), live-verified against the real Playwright MCP server; HTTP/SSE transport not yet built |
| 8 | Repository intelligence and memory | Done — `lib/core/context/` (indexer + ranked search) and `lib/core/memory/` (persistent, searchable), both wired into the UI |
| 9 | Browser/computer use | Browser done via Playwright MCP bridge (`lib/core/browser/`), live-verified (25 real tools discovered). Computer-use session control (PAUSE/STOP/EMERGENCY STOP, Policy Engine gating) done and tested (`lib/core/computer/`); the macOS Accessibility *driver* itself is a documented stub — genuinely cannot be built or verified without a macOS host (no display, no Accessibility API, no Xcode in this container) |
| 10 | Device/ADB/iOS integration | Done — `lib/core/devices/` wraps real `adb`/`xcrun simctl`, correctly reports zero devices in this container (neither SDK installed) rather than fabricating data |
| 11 | Autonomous repair loop | Task/step model done (`lib/core/tasks/`); full closed-loop wiring connecting the Orchestrator's repair cycle to a running Task's steps end-to-end is the remaining integration work |
| 12 | Independent review | Done (`lib/core/review/`) |
| 13 | Claude final-review integration | Done, abstraction + wiring (`CLAUDE_REVIEW.md`); needs a configured Anthropic key to exercise live |
| 14 | Security hardening | Core model done (`SECURITY.md`); OS-level sandboxing not yet built |
| 15 | Full acceptance suite | Partially exercised — see `TESTING.md` for which of the 25 tests are covered today |
| 16 | XCVF proving mission | Not started — explicitly out of scope until this platform's own milestones are further along, and only ever read-only against XCVF first, per the brief |

## Reproducing the live verifications

Two subsystems were connected to real external processes/services during development,
not just unit-tested against fakes:

```bash
# NVIDIA NIM — real, unauthenticated model catalogue listing
dart run bin/forge.dart models

# Playwright MCP — spawns a real `npx -y @playwright/mcp@latest` subprocess and
# discovers its live tool list over the actual MCP stdio JSON-RPC protocol.
# There is no `dart run -e` inline-eval flag, so save the snippet below as
# bin/_playwright_check.dart and run `dart run bin/_playwright_check.dart`:
cat > bin/_playwright_check.dart <<'DART'
import 'package:forge/core/mcp/mcp_client.dart';
import 'package:forge/core/mcp/mcp_transport.dart';

Future<void> main() async {
  final client = McpClient(
    serverId: 'playwright',
    transport: StdioMcpTransport(command: 'npx', args: ['-y', '@playwright/mcp@latest']),
  );
  await client.connect();
  await client.refreshCapabilities();
  print(client.tools.map((t) => t.name).toList());
  await client.disconnect();
}
DART
dart run bin/_playwright_check.dart
rm bin/_playwright_check.dart
```

Both require network access (npm registry / NVIDIA's API) and, for the second, Node.js
(`npx`) on `PATH`. This exact sequence produced the 25-tool list documented in
`lib/core/browser/playwright_mcp.dart`.

This table is maintained honestly: an item marked "not yet built" has no fake UI or stub
data pretending otherwise — see each relevant panel in `lib/ui/panels/placeholder_panel.dart`
usages for the in-app equivalent of this table.

## Repository layout

See `ARCHITECTURE.md#layers`.

## Code style

- No comments explaining *what* code does; only *why*, where non-obvious (see any file in
  `lib/core/tools/policy_engine.dart` for examples — security decisions are commented,
  getters are not).
- Every `Future`-returning core API is tested against a fake/injectable dependency
  (`ProcessRunner`, `McpTransport`, `FakeModelProvider`) rather than a real subprocess or
  network call in unit tests — see `TESTING.md`.
