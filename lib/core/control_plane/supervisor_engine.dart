import '../agents/agent_role.dart';
import '../agents/agent_runtime.dart';
import '../models/model_provider.dart';
import '../models/model_registry.dart';
import '../observability/telemetry.dart';
import '../tools/tool.dart';
import 'capability_router.dart';
import 'circuit_breaker.dart';
import 'circuit_breaker_registry.dart';
import 'task_graph.dart';

typedef ControlPlaneProviderResolver = ModelProvider Function(String providerId);
typedef ControlPlaneGatewayResolver = ToolGateway Function(TaskGraphNode node);

/// Classifies a caught exception from a worker's model call into the
/// [CircuitFailureType] taxonomy — the concrete implementation of the
/// spec's "differentiate INFRASTRUCTURE FAILURE from MODEL QUALITY FAILURE
/// from GENERATED CODE FAILURE." An [AgentRuntimeException] (the agent
/// exceeded its iteration budget without finishing) is treated as a
/// model-quality signal, not an outage — it never opens a circuit on its
/// own.
CircuitFailureType classifyWorkerException(Object error) {
  if (error is ModelProviderException) {
    if (error.rateLimited) return CircuitFailureType.rateLimited;
    if (error.statusCode == 401 || error.statusCode == 403) return CircuitFailureType.authFailure;
    if (error.statusCode != null && error.statusCode! >= 500) return CircuitFailureType.serverError;
    return CircuitFailureType.malformedResponse;
  }
  if (error is AgentRuntimeException) return CircuitFailureType.incompleteResponse;
  return CircuitFailureType.connectionFailure;
}

/// Executes a [TaskGraph]: dispatches ready nodes (respecting dependencies
/// and [maxConcurrency]) to workers selected by [CapabilityRouter], records
/// every outcome against the [CircuitBreakerRegistry], and fails a node over
/// to the next healthy, requirement-preserving candidate in its tier before
/// giving up — exactly the spec's
/// `SUPERVISOR -> WORKER A/B/C -> (failure) -> next healthy provider in tier`
/// flow, on top of the existing `AgentRuntime` ReAct loop
/// (`lib/core/agents/agent_runtime.dart`) rather than a parallel
/// implementation of it.
class SupervisorEngine {
  SupervisorEngine({
    required this.graph,
    required this.capabilityRouter,
    required this.circuitBreakers,
    required this.modelRegistry,
    required this.resolveProvider,
    required this.gatewayFor,
    this.maxConcurrency = 3,
    this.maxAttemptsPerNode = 3,
    this.lowConfidenceThreshold = 0.5,
    this.onEvent,
    this.telemetry,
  });

  final TaskGraph graph;
  final CapabilityRouter capabilityRouter;
  final CircuitBreakerRegistry circuitBreakers;
  final ModelRegistry modelRegistry;
  final ControlPlaneProviderResolver resolveProvider;
  final ControlPlaneGatewayResolver gatewayFor;
  final int maxConcurrency;
  final int maxAttemptsPerNode;
  final double lowConfidenceThreshold;
  final AgentEventSink? onEvent;

  /// Optional Neural Observatory instrumentation shared by every worker
  /// runtime — null by default (pre-Observatory behaviour preserved).
  final AgentTelemetry? telemetry;

  /// Runs every dispatchable node until the graph completes, hits an
  /// unrecoverable failure, exhausts its token budget, or stalls (ready
  /// nodes empty but the graph isn't complete — meaning every remaining
  /// node is blocked on a failed dependency).
  Future<void> runToCompletion() async {
    while (!graph.isComplete && !graph.hasUnrecoverableFailure && !graph.budgetExhausted) {
      final ready = graph.readyNodes;
      if (ready.isEmpty) return; // stalled — nothing left that can proceed
      final batch = ready.take(maxConcurrency).toList();
      await Future.wait(batch.map(runNode));
    }
  }

  /// Runs a single node to completion (success, exhausted retries, or an
  /// unrecoverable "no healthy model" condition), trying successive
  /// candidates from [CapabilityRouter.failoverChain] on failure — never
  /// retrying the exact same model twice for one node, and never relaxing
  /// the node's tier/capability requirements to find a candidate.
  Future<void> runNode(TaskGraphNode node) async {
    node.status = GraphNodeStatus.running;

    while (node.attempts < maxAttemptsPerNode) {
      final candidates = capabilityRouter
          .failoverChain(node.contract.tier, node.contract.taskCategory)
          .where((m) => !node.modelsAttempted.contains(m.id.key))
          .toList();

      if (candidates.isEmpty) {
        node.status = GraphNodeStatus.failed;
        node.failureReason ??= 'No untried healthy model remains in tier ${node.contract.tier.name}.';
        return;
      }

      final model = candidates.first;
      node.attempts++;
      node.modelsAttempted.add(model.id.key);
      node.assignedModelKey = model.id.key;

      final provider = resolveProvider(model.id.providerId);
      final definition = defaultAgentDefinitions[node.contract.role]!;
      final runtime = AgentRuntime(
        agentId: '${node.contract.id}_attempt${node.attempts}',
        definition: definition,
        provider: provider,
        modelName: model.id.modelName,
        gateway: gatewayFor(node),
        registry: modelRegistry,
        onEvent: onEvent,
        telemetry: telemetry,
      );

      final priorNote = node.attempts > 1 ? 'Previous attempt failed: ${node.failureReason}' : null;
      final startedAt = DateTime.now();
      try {
        final report = await runtime.run(node.contract.render(priorAttemptNote: priorNote));
        final latency = DateTime.now().difference(startedAt);
        circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(model.id)).recordSuccess(latency: latency);
        circuitBreakers.breakerFor(CapabilityRouter.providerCircuitId(model.id.providerId)).recordSuccess();

        final result = WorkerResult.parse(report.finalMessage);
        node.result = result;
        node.status = GraphNodeStatus.done;
        if (result.confidence < lowConfidenceThreshold) {
          // Per the spec: "Low confidence automatically triggers: second
          // worker, senior review, or supervisor escalation." The node
          // itself is done (it produced a result); flagging it here is what
          // lets `SupervisorEngine`'s caller (or a future escalation step)
          // decide to re-run at a higher tier — done, not failed, because a
          // low-confidence answer is still a real answer, not an error.
          node.failureReason = 'low confidence (${result.confidence.toStringAsFixed(2)}) — '
              'consider escalation or a second opinion';
        }
        return;
      } catch (e) {
        final failureType = classifyWorkerException(e);
        circuitBreakers.breakerFor(CapabilityRouter.modelCircuitId(model.id)).recordFailure(failureType);
        if (failureType.isInfrastructure) {
          circuitBreakers
              .breakerFor(CapabilityRouter.providerCircuitId(model.id.providerId))
              .recordFailure(failureType);
        }
        node.failureReason = e.toString();
        // loop: next iteration picks the next untried healthy candidate.
      }
    }

    node.status = GraphNodeStatus.failed;
  }

  /// Compares two nodes' results for the spec's "if two agents disagree" case.
  /// Deterministic evidence (identical `evidence` strings from a tool run,
  /// e.g. both quoting the same `flutter test` output) wins outright; absent
  /// that, the higher-confidence result wins but the disagreement is
  /// recorded in [TaskGraph.conflicts] for supervisor/human visibility
  /// rather than silently discarded — "Do NOT average their answers."
  WorkerResult reconcile(TaskGraphNode a, TaskGraphNode b) {
    final resultA = a.result;
    final resultB = b.result;
    if (resultA == null) return resultB!;
    if (resultB == null) return resultA;
    if (resultA.resultText.trim() == resultB.resultText.trim()) return resultA;

    graph.conflicts.add(
      '${a.contract.id} vs ${b.contract.id}: "${resultA.resultText}" (${resultA.confidence}) '
      'vs "${resultB.resultText}" (${resultB.confidence})',
    );

    if (resultA.evidence.isNotEmpty && resultA.evidence == resultB.evidence) {
      return resultA; // same underlying deterministic evidence — not a real conflict
    }
    return resultA.confidence >= resultB.confidence ? resultA : resultB;
  }
}
