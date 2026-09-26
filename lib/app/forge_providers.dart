import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/computer/computer_control_session.dart';
import '../core/computer/computer_control_driver.dart';
import '../core/context/repo_index.dart';
import '../core/context/repo_indexer.dart';
import '../core/control_plane/capability_router.dart';
import '../core/control_plane/circuit_breaker_registry.dart';
import '../core/control_plane/credential_vault.dart';
import '../core/control_plane/model_tier.dart';
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

/// Real, in-process secure secret storage. Swapped for [KeychainSecretsStore]
/// automatically once running on macOS with the platform channel wired up —
/// see PROVIDERS.md#secrets.
final secretsStoreProvider = Provider<SecretsStore>((ref) => InMemorySecretsStore());

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

/// Multi-credential-per-provider storage (`NVIDIA_KEY_1`/`NVIDIA_KEY_2`
/// style deployments) on top of the same [SecretsStore] every provider
/// adapter already uses — see `CredentialVault`'s class doc for the "never
/// use rotation to evade a rate limit" boundary this enforces.
final credentialVaultProvider = Provider<CredentialVault>((ref) {
  return CredentialVault(ref.watch(secretsStoreProvider));
});

/// One circuit per provider (`nvidia-nim`) and one per (provider, model)
/// (`nvidia-nim::kimi-k3`), shared by the plain [ModelRouter] below and by
/// [CapabilityRouter]/`SupervisorEngine` for the tiered Task Graph path.
final circuitBreakerRegistryProvider = Provider<CircuitBreakerRegistry>((ref) => CircuitBreakerRegistry());

final tierRegistryProvider = Provider<TierRegistry>((ref) => TierRegistry());

/// The Control Plane's capability-and-health-aware router, sitting above
/// the plain [ModelRouter] per `ARCHITECTURE.md`'s layering — used by
/// `SupervisorEngine` for tiered Task Graph dispatch.
final capabilityRouterProvider = Provider<CapabilityRouter>((ref) {
  return CapabilityRouter(
    modelRegistry: ref.watch(modelRegistryProvider),
    tierRegistry: ref.watch(tierRegistryProvider),
    circuitBreakers: ref.watch(circuitBreakerRegistryProvider),
    policy: ref.watch(routingPolicyProvider),
  );
});

final modelRouterProvider = Provider<ModelRouter>((ref) {
  final circuitBreakers = ref.watch(circuitBreakerRegistryProvider);
  return ModelRouter(
    registry: ref.watch(modelRegistryProvider),
    policy: ref.watch(routingPolicyProvider),
    isCircuitAvailable: (id) => circuitBreakers.breakerFor(id).isAvailable,
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
