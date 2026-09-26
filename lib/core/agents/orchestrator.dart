import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/model_provider.dart';
import '../models/model_registry.dart';
import '../models/model_router.dart';
import '../models/task_classifier.dart';
import '../tools/tool.dart';
import 'agent_role.dart';
import 'agent_runtime.dart';

/// Hard limits preventing runaway recursive agent creation, per the brief:
/// "Prevent infinite recursive agent creation."
class SubagentBudget {
  const SubagentBudget({
    this.maxDepth = 3,
    this.maxConcurrency = 4,
    this.maxTotalAgents = 20,
    this.perAgentTimeout = const Duration(minutes: 10),
  });

  final int maxDepth;
  final int maxConcurrency;
  final int maxTotalAgents;
  final Duration perAgentTimeout;
}

class SubagentBudgetExceededException implements Exception {
  SubagentBudgetExceededException(this.message);
  final String message;
  @override
  String toString() => 'SubagentBudgetExceededException: $message';
}

/// A bounded request to investigate or act on something, dispatched by the
/// Orchestrator to one specialist role. Depth-tracked so a subagent cannot
/// itself spawn agents beyond [SubagentBudget.maxDepth].
class SubagentRequest {
  const SubagentRequest({required this.role, required this.prompt, this.taskCategory});
  final AgentRole role;
  final String prompt;
  final TaskCategory? taskCategory;
}

/// Provider resolution: given a provider id, returns the live
/// [ModelProvider] instance. Kept as a function rather than a fixed map so
/// the Orchestrator doesn't need to know about every concrete provider
/// class.
typedef ProviderResolver = ModelProvider Function(String providerId);

/// Implements the brief's
/// `ORCHESTRATOR -> SPECIALIST AGENTS -> TOOLS -> OBSERVATION -> ... -> COMPLETE`
/// loop with bounded, dependency-free parallel execution, a hard recursion
/// depth limit, a total-agent-count budget, and cooperative cancellation.
class AgentOrchestrator {
  AgentOrchestrator({
    required this.registry,
    required this.router,
    required this.resolveProvider,
    required this.gatewayFor,
    this.budget = const SubagentBudget(),
    this.onEvent,
    this.onModelOutcome,
    Map<AgentRole, AgentDefinition>? definitions,
  }) : definitions = definitions ?? defaultAgentDefinitions;

  final ModelRegistry registry;
  final ModelRouter router;
  final ProviderResolver resolveProvider;

  /// Each spawned agent gets its own [ToolGateway] view (same underlying
  /// Policy Engine/audit log, but this indirection lets callers hand a
  /// role-scoped gateway when needed — e.g. a browser-only gateway for
  /// [AgentRole.browser]).
  final ToolGateway Function(AgentRole role) gatewayFor;
  final SubagentBudget budget;
  final AgentEventSink? onEvent;

  /// Control Plane integration point: called with the selected [ModelId]
  /// and either `null` (success) or the thrown error after every spawned
  /// agent's model call completes or fails. Wired to
  /// `CircuitBreakerRegistry` by callers that use the Control Plane
  /// extension (`lib/core/control_plane/`) so a plain [AgentOrchestrator]
  /// run — not just [SupervisorEngine]'s task-graph path — still feeds
  /// circuit-breaker state. `null` (the default) keeps this class fully
  /// independent of the control-plane layer.
  final void Function(ModelId modelId, Object? error)? onModelOutcome;
  final Map<AgentRole, AgentDefinition> definitions;

  final _uuid = const Uuid();
  int _totalSpawned = 0;
  bool _cancelled = false;

  int get totalSpawned => _totalSpawned;
  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  /// Runs one subagent for [request] at recursion [depth] (0 = top-level,
  /// spawned directly by the orchestrating task rather than by another
  /// agent).
  Future<AgentReport> spawn(SubagentRequest request, {int depth = 0}) async {
    if (_cancelled) {
      throw SubagentBudgetExceededException('Orchestrator run was cancelled.');
    }
    if (depth > budget.maxDepth) {
      throw SubagentBudgetExceededException(
        'Max subagent depth (${budget.maxDepth}) exceeded.',
      );
    }
    if (_totalSpawned >= budget.maxTotalAgents) {
      throw SubagentBudgetExceededException(
        'Max total agents (${budget.maxTotalAgents}) for this task exceeded.',
      );
    }
    _totalSpawned++;

    final definition = definitions[request.role];
    if (definition == null) {
      throw ArgumentError('No AgentDefinition registered for ${request.role}');
    }
    final category = request.taskCategory ?? definition.defaultTaskCategory;
    final model = router.selectModel(category);
    final provider = resolveProvider(model.id.providerId);
    final agentId = '${request.role.name}_${_uuid.v4().substring(0, 8)}';

    final runtime = AgentRuntime(
      agentId: agentId,
      definition: definition,
      provider: provider,
      modelName: model.id.modelName,
      gateway: gatewayFor(request.role),
      registry: registry,
      onEvent: onEvent,
    );

    onEvent?.call(AgentEvent(
      agentId,
      request.role,
      'spawned at depth $depth using ${model.id.key}',
    ));

    try {
      final report = await runtime.run(request.prompt).timeout(
        budget.perAgentTimeout,
        onTimeout: () => throw SubagentBudgetExceededException(
          'Agent $agentId (${request.role.name}) exceeded '
          '${budget.perAgentTimeout.inSeconds}s timeout.',
        ),
      );
      onModelOutcome?.call(model.id, null);
      return report;
    } catch (e) {
      onModelOutcome?.call(model.id, e);
      rethrow;
    }
  }

  /// Runs independent [requests] concurrently, bounded by
  /// [SubagentBudget.maxConcurrency]. Used for the brief's "Investigate why
  /// X" example: several independent investigations dispatched at once,
  /// results returned to the orchestrator together.
  ///
  /// One agent failing no longer aborts the whole batch: every request gets
  /// to run, partial results are preserved, and per-request failures (already
  /// reported through [onModelOutcome] inside [spawn], feeding circuit
  /// breakers) are returned alongside the successful reports.
  Future<ParallelSpawnResult> spawnParallel(
    List<SubagentRequest> requests, {
    int depth = 0,
  }) async {
    final reports = <AgentReport>[];
    final failures = <SpawnFailure>[];
    for (var i = 0; i < requests.length; i += budget.maxConcurrency) {
      if (_cancelled) {
        // Stop dispatching new batches; already-running agents finish (or
        // hit their timeout) but nothing further is spawned.
        break;
      }
      final batch = requests.skip(i).take(budget.maxConcurrency);
      final batchResults = await Future.wait(
        batch.map((r) async {
          try {
            return await spawn(r, depth: depth);
          } catch (e) {
            return SpawnFailure._(r, e);
          }
        }),
      );
      for (final result in batchResults) {
        if (result is SpawnFailure) {
          failures.add(result);
        } else if (result is AgentReport) {
          reports.add(result);
        }
      }
    }
    return ParallelSpawnResult._(reports, failures);
  }
}

/// One failed request from a [AgentOrchestrator.spawnParallel] batch, with
/// the error that killed it. [SpawnFailure.error] has already been reported
/// through `onModelOutcome` (when wired), so circuit-breaker state stays
/// accurate.
class SpawnFailure {
  SpawnFailure._(this.request, this.error);
  final SubagentRequest request;
  final Object error;
}

/// Outcome of a parallel spawn: successful reports plus per-request
/// failures, so callers can reconcile partial results rather than losing
/// everything on one agent's infrastructure failure.
class ParallelSpawnResult {
  ParallelSpawnResult._(this.reports, this.failures);
  final List<AgentReport> reports;
  final List<SpawnFailure> failures;

  bool get allSucceeded => failures.isEmpty;
}

