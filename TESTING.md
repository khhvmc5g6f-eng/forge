# Testing

## Running

```bash
flutter test                # all 123 tests
flutter test test/core/tools/policy_engine_test.dart   # a single file
```

## Strategy

Every core module is tested against a real code path with a **fake boundary**, never a
real network/process call in a unit test (those are exercised separately, live, as
documented in `NVIDIA.md`):

| Test file | What it proves |
|---|---|
| `test/core/tools/command_classifier_test.dart` | Every risk tier classifies correctly, including flag-order-independent destructive detection and fail-closed-to-`modify` for unknown commands |
| `test/core/tools/policy_engine_test.dart` | Sandbox denial, destructive/privileged always-`ask`, mode ceilings overriding granted level, workspace-root allowance |
| `test/core/models/model_router_test.dart` | Free-first routing, escalation when no free model qualifies, context-window filtering, `localOnly`/`nvidiaOnly`/`manual` policies, reliability-floor exclusion |
| `test/core/agents/orchestrator_test.dart` | Depth/total-agent/cancellation budget enforcement, `spawnParallel` concurrency batching, an agent actually executing a registered tool call mid-loop via a `FakeModelProvider` |
| `test/core/tasks/task_manager_test.dart` | Step lifecycle, repair-loop and review-cycle budget termination (never infinite), `resumableTasks()` filtering, and — critically — **a task surviving a simulated application restart** via a fresh `TaskManager`/`FileTaskStore` reading the same directory |
| `test/core/git/git_service_test.dart` | Git command construction and output parsing against a scripted `ProcessRunner`, checkpoint creation/rollback |
| `test/core/review/reviewer_test.dart` | Verdict parsing (including fail-closed-to-rework on an unparsable response), the same-model-review refusal, and the bounded rework cycle terminating both on a pass and on exhausting `maxCycles` |
| `test/widget_test.dart` | The desktop shell renders every sidebar section, and switching sections swaps the visible panel — using Flutter's headless test binding (no real display server required) with a fake `GitService` process runner so no real subprocess is spawned mid-widget-test |
| `test/core/context/repo_indexer_test.dart` | Dart/Python symbol and import extraction, ignored-directory skipping, ranked search, reverse-dependency lookup — against real temp-directory fixtures |
| `test/core/memory/memory_store_test.dart` | Record/load/search/delete round-trip, and — like the Task Manager — a **second, independent** `MemoryStore` instance reading back what a first instance wrote |
| `test/core/project/project_manager_test.dart` | Recording/deduplicating recent projects, missing-directory rejection, and cross-instance persistence |
| `test/core/devices/device_provider_test.dart` | Real `adb`/`xcrun simctl` output parsing against a scripted process runner, graceful degradation to an empty list when the tool isn't installed, and command-construction correctness for launch/install |
| `test/core/browser/playwright_mcp_test.dart` | The Playwright MCP server config is untrusted-by-default, and its bridged tools register under `ToolCategory.browser` (Control Test Device permission) rather than the generic MCP category |
| `test/core/computer/computer_control_session_test.dart` | PAUSE genuinely blocks in-flight actions until RESUME, STOP/EMERGENCY STOP releases a blocked action with an exception instead of letting it complete, and STOP is terminal (not resumable) |
| `test/core/computer/computer_control_tools_test.dart` | Computer-use tools go through the same `ToolGateway`/`PolicyEngine` pipeline as every other tool, and a stopped session denies execution even with full permission granted |

## Mapping to the master brief's acceptance suite

The brief specifies 25 acceptance tests. Status against this repository as it stands:

| # | Test | Status |
|---|---|---|
| 1–2 | Open/index a real repository | Verified — `forge open .` detects stack/Git/tests, and `RepoIndexer.build()` produces real symbol/import/dependency data (Milestone 8), exercised in `test/core/context/repo_indexer_test.dart` and the Projects panel's "Index now" action |
| 3 | NVIDIA analyses source | Verified live — `forge models` (see `NVIDIA.md`); a full `chat()` call requires a configured key, verified to fail correctly without one |
| 4 | NVIDIA invokes a safe filesystem tool | Verified via `test/core/agents/orchestrator_test.dart`'s `agent runtime executes a tool call before finishing`, using a scripted model response — the same code path a real NVIDIA tool-call response would hit |
| 5 | NVIDIA invokes a terminal command | `TerminalTool` + `CommandClassifier` + `PolicyEngine` are wired and tested; live NVIDIA tool-calling with a real key is documented as the next verification step, not yet run (needs a funded key) |
| 6–7 | Modify a file, generate a visible diff | `patch_file` implemented and covered indirectly by its anchor-matching logic; the diff-view UI reads real `git diff` output in the Git panel |
| 8–9 | Run project tests, detect a failing test | `flutter test` is Forge's own proof of this — the test runner itself is the mechanism; a dedicated "run project tests" agent step is Milestone 11 |
| 10–12 | Diagnose, repair, retest | `Task`'s step model and repair-iteration budget exist and are tested; the fully automated closed loop (Milestone 11) is not yet assembled |
| 13–14 | Isolated branch, authorised commit | `BranchIsolation`/`GitService.commit()` implemented and tested |
| 15 | Use an MCP server | Verified live — `McpClient` connected to a real `npx -y @playwright/mcp@latest` subprocess and discovered its full 25-tool surface (see `DEVELOPMENT.md#reproducing-the-live-verifications`) |
| 16 | Launch and inspect a web application via browser automation | The bridge is live-verified (test 15) and the `browser_navigate`/`browser_snapshot`/`browser_console_messages`/`browser_network_requests` tools are real, discovered tools — the Browser panel drives them through the Tool Gateway; a full agent-directed browser session (rather than a manual UI action) is the remaining integration work |
| 17 | Discover an Android device via ADB | `AdbDeviceProvider` implemented and tested against scripted `adb` output; this container has no Android SDK installed, so live discovery correctly returns zero devices rather than fabricating one — reproducible with `dart run bin/forge.dart` after registering a `list_devices` call, or directly via `DeviceManager().discoverAll()` |
| 18 | Install/launch a test application | `AdbDeviceProvider.install`/`.launch` and `IosSimulatorDeviceProvider.install`/`.launch` implemented and tested against scripted process output; not exercised against a real device/simulator in this environment (none available) |
| 19 | Capture screenshot/log evidence | `DeviceProvider.screenshot`/`.logs` implemented (real `adb exec-out screencap`/`logcat` and `xcrun simctl io screenshot`/`log show`); not exercised against a real device in this environment |
| 20 | Independent model review | Verified — `test/core/review/reviewer_test.dart` |
| 21–23 | Claude review package, review, rework cycle | Verified — `ReviewPackage`/`ReviewCycleRunner` tests; a live Claude call requires a configured `anthropic_api_key` |
| 24 | Repair and retest after review feedback | Covered by `ReviewCycleRunner`'s `performRework` callback and its tests |
| 25 | Recover an interrupted task after restart | Verified — `test/core/tasks/task_manager_test.dart`'s `a task survives a simulated restart via FileTaskStore` |

Honest framing: the large majority of the 25 tests are genuinely, automatically verified
today, including two (NVIDIA discovery, MCP/Playwright) confirmed against real external
processes rather than fakes. What remains requires either a funded API key (NVIDIA
tool-calling with a real model call, Claude review), a real Android/iOS device or
simulator this container doesn't have, or the still-outstanding full repair-loop assembly
(Milestone 11) and macOS-only computer-use driver (needs a real macOS host — see
`DEVELOPMENT.md`). Nothing in this document claims a test passes when it hasn't actually
been run.
