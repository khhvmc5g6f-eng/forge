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
import '../core/local_models/ollama_runtime.dart';
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
import '../core/observability/counting_http_client.dart';
import '../core/observability/observatory_service.dart';
import '../core/observability/resource_sampler.dart';
import '../core/observability/telemetry_store.dart';
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

/// Live phase of the built-in local-model runtime, mirrored from
/// [ollamaRuntimeProvider]'s onPhaseChange so the Models panel can watch it
/// reactively.
final localRuntimePhaseProvider =
    StateProvider<LocalRuntimePhase>((ref) => LocalRuntimePhase.notInstalled);

/// Forge's **built-in** local-model runtime (`lib/core/local_models/`):
/// Forge provisions the Ollama server binary under
/// `~/.forge/runtime/ollama/bin`, stores pulled models under
/// `~/.forge/runtime/ollama/models` (never `~/.ollama`), and supervises the
/// `serve` process itself — no separate Ollama installation. The Models
/// panel's Start/Stop/Pull controls and "Refresh local" both go through
/// this provider; the existing `OllamaProvider` adapter simply points at
/// the managed endpoint.
final ollamaRuntimeProvider = Provider<OllamaRuntime>((ref) {
  final runtime = OllamaRuntime(
    onPhaseChange: (phase) =>
        ref.read(localRuntimePhaseProvider.notifier).state = phase,
  );
  ref.onDispose(runtime.stop);
  return runtime;
});

// ── Neural Observatory (lib/core/observability/) ─────────────────────────
// One shared telemetry service beneath the entire application: the
// in-session panel, the Observatory workspace, the CLI and the
// self-improvement engine all read this same instance, so a diagnostic
// seen in one surface is the same data every other surface shows.

/// Host resource sampling: process CPU/RSS via `ps` (measured); GPU is
/// reported honestly as unavailable until a real telemetry source for
/// one is wired.
final resourceSamplerProvider = Provider<ResourceSampler>(
    (ref) => ResourceSampler());

final Provider<ObservatoryService> observatoryServiceProvider =
    Provider<ObservatoryService>((ref) {
  final service = ObservatoryService(
    telemetryStore: JsonlTelemetryStore(ref.watch(projectRootProvider)),
  );
  final circuitBreakers = ref.watch(circuitBreakerRegistryProvider);
  // Provider/key health comes from the Control Plane — masked internal
  // references only; the credential itself never crosses this boundary.
  service.providerStatusReader = () {
    final providerIds = ref.read(allModelProvidersProvider).keys;
    final rows = <ProviderStatusRow>[];
    for (final providerId in providerIds) {
      final breaker = circuitBreakers
          .breakerFor(CapabilityRouter.providerCircuitId(providerId));
      rows.add(ProviderStatusRow(
        providerId: providerId,
        keyRef: 'primary',
        circuitState: breaker.state.name,
        requests: breaker.totalRequests,
        failures: breaker.totalFailures,
        rateLimited: breaker.total429s,
        averageLatencyMs: breaker.averageLatency.inMilliseconds,
      ));
    }
    return rows;
  };
  return service;
});

/// Passive network byte counting for every provider request — the same
/// adapters, wrapped once, so the Observatory measures real application
/// traffic (never presented as the user's connection speed).
final Provider<CountingHttpClient> countingHttpClientProvider =
    Provider<CountingHttpClient>((ref) {
  final observatory = ref.watch(observatoryServiceProvider);
  return CountingHttpClient(
    onTraffic: (bytesOut, bytesIn, url, at) => observatory.recordNetworkTraffic(
      bytesOut: bytesOut,
      bytesIn: bytesIn,
      url: url,
    ),
  );
});

/// Every configured provider adapter, keyed by provider id — the Control
/// Plane's "federated" fleet: NVIDIA NIM, Groq, Cerebras, OpenRouter, Z.AI,
/// Google, Anthropic, OpenAI, and local (Ollama/LM Studio). All HTTP goes
/// through [countingHttpClientProvider] so the Observatory passively
/// measures real traffic. Used by the Models panel's refresh actions, the
/// Control Centre, and `SupervisorEngine.resolveProvider`.
final Provider<Map<String, ModelProvider>> allModelProvidersProvider =
    Provider<Map<String, ModelProvider>>((ref) {
  final secrets = ref.watch(secretsStoreProvider);
  final http = ref.watch(countingHttpClientProvider);
  return {
    'nvidia-nim': NvidiaNimProvider(secretsStore: secrets, httpClient: http),
    'groq': GroqProvider(secretsStore: secrets, httpClient: http),
    'cerebras': CerebrasProvider(secretsStore: secrets, httpClient: http),
    'openrouter': OpenRouterProvider(secretsStore: secrets, httpClient: http),
    'zai': ZaiProvider(secretsStore: secrets, httpClient: http),
    'google': GoogleProvider(secretsStore: secrets, httpClient: http),
    'anthropic': AnthropicProvider(secretsStore: secrets, httpClient: http),
    'openai': OpenAiProvider(secretsStore: secrets, httpClient: http),
    'ollama': OllamaProvider(secretsStore: secrets, httpClient: http),
    'lm-studio': LmStudioProvider(secretsStore: secrets, httpClient: http),
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
