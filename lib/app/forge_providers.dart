import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/computer/computer_control_session.dart';
import '../core/computer/computer_control_driver.dart';
import '../core/context/repo_index.dart';
import '../core/context/repo_indexer.dart';
import '../core/devices/device_manager.dart';
import '../core/git/checkpoint.dart';
import '../core/git/git_service.dart';
import '../core/mcp/mcp_manager.dart';
import '../core/memory/memory_store.dart';
import '../core/project/project_manager.dart';
import '../core/models/model_provider.dart';
import '../core/models/model_registry.dart';
import '../core/models/model_router.dart';
import '../core/models/providers/additional_providers.dart';
import '../core/models/providers/anthropic_provider.dart';
import '../core/models/providers/local_providers.dart';
import '../core/models/providers/nvidia_nim_provider.dart';
import '../core/security/keychain_secrets_store.dart';
import '../core/security/secrets_store.dart';
import '../core/tasks/task_manager.dart';
import '../core/tasks/task_store.dart';
import '../core/tools/policy_engine.dart';
import '../core/tools/terminal_tool.dart';
import '../core/tools/tool.dart';
import '../core/tools/tool_category.dart';
import '../core/tools/filesystem_tools.dart';
import '../core/computer/computer_control_tools.dart';
import '../core/devices/device_tools.dart';
import '../core/git/git_tools.dart';

/// The project currently open in the workstation. Defaults to the process's
/// working directory so the app is immediately usable via `forge open .`;
/// the Projects panel lets the user switch it.
final projectRootProvider = StateProvider<String>((ref) => Directory.current.path);

final operatingModeProvider = StateProvider<OperatingMode>((ref) => OperatingMode.agent);
final permissionLevelProvider =
    StateProvider<PermissionLevel>((ref) => PermissionLevel.proposeEdits);
final routingPolicyProvider = StateProvider<RoutingPolicy>((ref) => RoutingPolicy.auto);

/// Secure secret storage. Uses the real macOS Keychain-backed
/// [KeychainSecretsStore] when running as a desktop app on macOS; falls back
/// to [InMemorySecretsStore] in unit tests (no platform channel) and on
/// hosts without secure storage. See PROVIDERS.md#secrets.
final secretsStoreProvider = Provider<SecretsStore>((ref) {
  final inTestEnv = Platform.environment.containsKey('FLUTTER_TEST');
  if (!inTestEnv && Platform.isMacOS) {
    return KeychainSecretsStore(serviceName: 'app.forge.secrets');
  }
  return InMemorySecretsStore();
});

final gitServiceProvider = Provider<GitService>((ref) {
  return GitService(repositoryRoot: ref.watch(projectRootProvider));
});

final checkpointManagerProvider = Provider<CheckpointManager>((ref) {
  return CheckpointManager(ref.watch(gitServiceProvider));
});

final branchIsolationProvider = Provider<BranchIsolation>((ref) {
  return BranchIsolation(ref.watch(gitServiceProvider));
});

final taskManagerProvider = Provider<TaskManager>((ref) {
  return TaskManager(FileTaskStore(ref.watch(projectRootProvider)));
});

final modelRegistryProvider = Provider<ModelRegistry>((ref) => ModelRegistry());

/// Every configured provider adapter, keyed by provider id — the Control
/// Plane's "federated" fleet: NVIDIA NIM, Groq, Cerebras, OpenRouter, Z.AI,
/// Google, Anthropic, OpenAI, and local (Ollama/LM Studio). Used by the
/// Models panel's refresh actions, the Control Centre, and
/// `SupervisorEngine.resolveProvider`.
final allModelProvidersProvider = Provider<Map<String, ModelProvider>>((ref) {
  final secrets = ref.watch(secretsStoreProvider);
  return {
    'nvidia-nim': NvidiaNimProvider(secretsStore: secrets),
    'groq': GroqProvider(secretsStore: secrets),
    'cerebras': CerebrasProvider(secretsStore: secrets),
    'openrouter': OpenRouterProvider(secretsStore: secrets),
    'zai': ZaiProvider(secretsStore: secrets),
    'google': GoogleProvider(secretsStore: secrets),
    'anthropic': AnthropicProvider(secretsStore: secrets),
    'openai': OpenAiProvider(secretsStore: secrets),
    'ollama': OllamaProvider(secretsStore: secrets),
    'lm-studio': LmStudioProvider(secretsStore: secrets),
  };
});

// Control plane (circuit breakers, multi-key vault, capability routing, usage,
// alerts) now lives in the TypeScript Forge engine; the UI reads and drives it
// through `engineConnectionProvider` (lib/core/forge_engine). The previous Dart
// copies (lib/core/control_plane/*) are deprecated; see docs/ENGINE_API.md and
// CONTROL_PLANE.md for the migration note and what has no engine equivalent yet.

final modelRouterProvider = Provider<ModelRouter>((ref) {
  return ModelRouter(
    registry: ref.watch(modelRegistryProvider),
    policy: ref.watch(routingPolicyProvider),
  );
});

final policyEngineProvider = Provider<PolicyEngine>((ref) {
  return PolicyEngine(
    mode: ref.watch(operatingModeProvider),
    grantedLevel: ref.watch(permissionLevelProvider),
    projectRoot: ref.watch(projectRootProvider),
  );
});

/// Command execution history, appended to by every [TerminalTool] run —
/// backs the bottom-panel Terminal view.
final terminalHistoryProvider = StateProvider<List<CommandExecutionRecord>>((ref) => []);

final terminalToolProvider = Provider<TerminalTool>((ref) {
  return TerminalTool(
    workingDirectory: ref.watch(projectRootProvider),
    agentId: 'user',
    // Defense-in-depth: a hard `deny` from the Policy Engine is enforced at
    // the tool itself, not only at the Tool Gateway.
    policyEngine: ref.watch(policyEngineProvider),
    // Contain novel/unrecognised commands on macOS: Seatbelt denies file
    // writes outside the project root even if the rule-based classifier
    // mis-judges a command's risk.
    useSeatbelt: Platform.isMacOS,
    log: (record) {
      final list = [...ref.read(terminalHistoryProvider)];
      final idx = list.indexWhere((r) => identical(r, record));
      if (idx == -1) {
        list.add(record);
      } else {
        list[idx] = record;
      }
      ref.read(terminalHistoryProvider.notifier).state = list;
    },
  );
});

/// The single [ToolGateway] the UI's manual actions (and, once wired, the
/// agent runtime) invoke through — every tool call the user triggers from
/// the desktop shell goes through the same Policy Engine as an agent would.
final toolGatewayProvider = Provider<ToolGateway>((ref) {
  final gateway = ToolGateway(policyEngine: ref.watch(policyEngineProvider));
  registerFilesystemTools(gateway.register, ref.watch(projectRootProvider));
  registerGitTools(gateway.register, ref.watch(gitServiceProvider), ref.watch(projectRootProvider));
  gateway.register(ref.watch(terminalToolProvider));
  registerDeviceTools(gateway.register, ref.watch(deviceManagerProvider));
  registerComputerControlTools(gateway.register, ref.watch(computerControlSessionProvider));
  return gateway;
});

final mcpManagerProvider = Provider<McpManager>((ref) => McpManager());

final memoryStoreProvider = Provider<MemoryStore>((ref) {
  return MemoryStore(ref.watch(projectRootProvider));
});

/// The current [RepoIndex], if a build has been triggered. `null` means "not
/// indexed yet" — the Projects/Repository UI shows an explicit "Index now"
/// action rather than silently indexing on every project open (indexing a
/// large repository is not free).
final repoIndexProvider = StateProvider<RepoIndex?>((ref) => null);

final repoIndexerProvider = Provider<RepoIndexer>((ref) => RepoIndexer());

final projectManagerProvider = Provider<ProjectManager>((ref) => ProjectManager());

final deviceManagerProvider = Provider<DeviceManager>((ref) => DeviceManager());

/// Wraps `MacosAccessibilityDriver` — every method throws `UnimplementedError`
/// on this non-macOS development host until the real Accessibility platform
/// channel is built (see `lib/core/computer/computer_control_driver.dart`).
/// Registering the tools/session here is still correct: it wires the real
/// Policy Engine gating and PAUSE/STOP/EMERGENCY STOP session controls now,
/// so only the driver needs swapping once that platform channel exists.
final computerControlSessionProvider = Provider<ComputerControlSession>((ref) {
  final session = ComputerControlSession(MacosAccessibilityDriver());
  ref.onDispose(() => session.dispose());
  return session;
});
