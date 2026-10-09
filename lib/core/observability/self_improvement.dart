/// Neural Observatory — the autonomous self-improvement lifecycle.
///
/// The engine never edits code itself: it runs a gated state machine over
/// an [OptimisationJob], calling injected, observable operations
/// (implement/test/benchmark/review/deploy/rollback) that production wires
/// to the existing Orchestrator, TaskManager, `GitService` and test
/// runners. What the engine enforces is the control surface from the spec:
///
/// * **Observe** collects diagnostics only; **Investigate** stops at a
///   hypothesis; **Develop** runs the full pipeline on an isolated branch
///   but never deploys; **Controlled autonomy** deploys only authorised,
///   validated, low-risk changes.
/// * Protected scopes — the approval, audit, security, credential,
///   payment and migration mechanisms — **always** require explicit
///   authorisation, in every mode. This engine cannot be used to weaken
///   its own gates: an unauthorised job touching them stops cold.
/// * Regression criteria are evaluated from measured before/after
///   benchmark readings; a change that fails tests, regresses the target
///   metric, or is not independently approved is rolled back.
library;

import 'anomaly.dart';

enum AutonomyMode { observe, investigate, develop, controlledAutonomy }

enum JobPhase {
  hypothesisReady,
  awaitingAuthorisation,
  testing,
  benchmarking,
  reviewing,
  readyToDeploy,
  deployed,
  rolledBack,
  rejected,
  failed,
}

/// The subsystems a self-modification may never silently touch.
class ProtectedScope {
  static const List<String> fragments = [
    'policy_engine',
    'security',
    'secrets',
    'credential',
    'approval',
    'permission',
    'payment',
    'migration',
    'audit',
    'guard',
    'reviewer',
  ];

  static bool isProtected(String target) =>
      fragments.any((f) => target.toLowerCase().contains(f));
}

/// One benchmark pass: named metric readings taken under comparable
/// conditions. Values are the *measured* numbers from the benchmark
/// operation, whatever it is wired to.
class BenchmarkReading {
  const BenchmarkReading(this.metrics);

  final Map<String, double> metrics;

  double? operator [](String key) => metrics[key];
}

class OptimisationJob {
  OptimisationJob({
    required this.id,
    required this.originAnomalyId,
    required this.hypothesis,
    required this.targetMetric,
    required this.targetComponent,
    required this.higherIsBetter,
    required this.baseline,
  });

  final String id;
  final String originAnomalyId;

  /// A measurable, falsifiable claim — "switching X to Y reduces P95
  /// latency", never "make it faster".
  final String hypothesis;
  final String targetMetric;

  /// The file/subsystem the candidate change touches.
  final String targetComponent;
  final bool higherIsBetter;

  /// Measured *before* the change — no baseline, no change.
  final BenchmarkReading baseline;

  JobPhase phase = JobPhase.hypothesisReady;
  String branchName = '';
  String changeSummary = '';
  bool testsPassed = false;
  String testLog = '';
  BenchmarkReading? after;
  String reviewVerdict = '';
  bool authorised = false;

  final List<String> eventLog = [];

  bool get touchesProtectedScope =>
      ProtectedScope.isProtected(targetComponent);

  void log(String entry) =>
      eventLog.add('${DateTime.now().toIso8601String()}  $entry');
}

/// The operations the engine orchestrates. No default implementations
/// exist on purpose: an unwired operation is a hard stop, never a silent
/// no-op, and every operation is individually observable/mockable.
class SelfImprovementOperations {
  const SelfImprovementOperations({
    required this.implementChange,
    required this.runTests,
    required this.runBenchmark,
    required this.reviewChange,
    required this.deployChange,
    required this.rollbackChange,
  });

  /// Implements the candidate on an isolated branch; returns the branch
  /// name and a change summary.
  final Future<({String branchName, String summary})> Function(
      OptimisationJob job) implementChange;

  /// Runs the relevant automated tests for the change.
  final Future<({bool passed, String log})> Function(OptimisationJob job)
      runTests;

  /// Measures the target metric(s) on the changed branch.
  final Future<BenchmarkReading> Function(OptimisationJob job) runBenchmark;

  /// Independent review — a *different* model/agent than the author, per
  /// CLAUDE_REVIEW.md's author≠reviewer rule. Returns 'pass'|'rework'|'fail'.
  final Future<String> Function(OptimisationJob job) reviewChange;

  final Future<void> Function(OptimisationJob job) deployChange;
  final Future<void> Function(OptimisationJob job) rollbackChange;
}

class SelfImprovementEngine {
  SelfImprovementEngine(
    this.operations, {
    this.mode = AutonomyMode.observe,
    this.minImprovementFraction = 0.01,
  });

  final SelfImprovementOperations operations;
  AutonomyMode mode;

  /// A change must improve the target metric by at least this fraction of
  /// the baseline to count — noise is not progress.
  final double minImprovementFraction;

  final List<OptimisationJob> jobs = [];

  OptimisationJob proposeFromAnomaly(
    Anomaly anomaly, {
    required String hypothesis,
    required String targetMetric,
    required String targetComponent,
    required bool higherIsBetter,
    required Map<String, double> baselineMetrics,
  }) {
    if (mode == AutonomyMode.observe) {
      throw StateError(
          'Observe mode collects diagnostics only; switch to investigate '
          'or above to propose changes.');
    }
    final job = OptimisationJob(
      id: 'opt_${anomaly.id}',
      originAnomalyId: anomaly.id,
      hypothesis: hypothesis,
      targetMetric: targetMetric,
      targetComponent: targetComponent,
      higherIsBetter: higherIsBetter,
      baseline: BenchmarkReading(baselineMetrics),
    );
    job.log('proposed from anomaly ${anomaly.id} '
        '(metric ${anomaly.metric}, z=${anomaly.evidence['z']?.toStringAsFixed(2)})');
    jobs.add(job);
    return job;
  }

  /// Explicit human authorisation — the only way a protected scope or a
  /// deployment ever proceeds.
  void authorise(String jobId) {
    final job = _byId(jobId);
    job
      ..authorised = true
      ..log('explicitly authorised');
  }

  /// Advances the job one step through the lifecycle, enforcing every
  /// gate. Terminal phases are no-ops.
  Future<JobPhase> advance(OptimisationJob job) async {
    switch (job.phase) {
      case JobPhase.hypothesisReady:
        if (mode == AutonomyMode.investigate) {
          job.log('investigate mode: stopping at hypothesis (recommendation only)');
          return job.phase;
        }
        if (job.touchesProtectedScope && !job.authorised) {
          job
            ..phase = JobPhase.awaitingAuthorisation
            ..log('target touches a protected scope (${job.targetComponent}) '
                '— explicit authorisation required in every mode');
          return job.phase;
        }
        return _implement(job);

      case JobPhase.awaitingAuthorisation:
        if (!job.authorised) return job.phase;
        job.log('authorised — resuming pipeline');
        return _implement(job);

      case JobPhase.testing:
        final tests = await operations.runTests(job);
        job
          ..testsPassed = tests.passed
          ..testLog = tests.log;
        if (!tests.passed) {
          await operations.rollbackChange(job);
          job
            ..phase = JobPhase.rolledBack
            ..log('tests failed — change reverted. Log: ${tests.log}');
          return job.phase;
        }
        job
          ..phase = JobPhase.benchmarking
          ..log('tests passed');
        return job.phase;

      case JobPhase.benchmarking:
        final after = await operations.runBenchmark(job);
        job.after = after;
        if (_regressed(job)) {
          await operations.rollbackChange(job);
          job
            ..phase = JobPhase.rolledBack
            ..log('benchmark did not meet the improvement criterion — '
                'change reverted (baseline ${job.baseline[job.targetMetric]}, '
                'after ${after[job.targetMetric]})');
          return job.phase;
        }
        job
          ..phase = JobPhase.reviewing
          ..log('benchmark improved the target metric');
        return job.phase;

      case JobPhase.reviewing:
        final verdict = await operations.reviewChange(job);
        job.reviewVerdict = verdict;
        if (verdict != 'pass') {
          await operations.rollbackChange(job);
          job
            ..phase = JobPhase.rolledBack
            ..log('independent review verdict "$verdict" — change reverted');
          return job.phase;
        }
        job
          ..phase = JobPhase.readyToDeploy
          ..log('independent review passed');
        return job.phase;

      case JobPhase.readyToDeploy:
        if (mode != AutonomyMode.controlledAutonomy) {
          job.log('deploy blocked: mode is ${mode.name}, not controlledAutonomy');
          return job.phase;
        }
        if (!job.authorised) {
          job.log('deploy blocked: no explicit authorisation for deployment');
          return job.phase;
        }
        await operations.deployChange(job);
        job
          ..phase = JobPhase.deployed
          ..log('deployed under controlled autonomy');
        return job.phase;

      case JobPhase.deployed:
      case JobPhase.rolledBack:
      case JobPhase.rejected:
      case JobPhase.failed:
        return job.phase;
    }
  }

  /// The implement step, shared by the fresh-pipeline path and the
  /// authorised-resume path: run the change on an isolated branch.
  Future<JobPhase> _implement(OptimisationJob job) async {
    final implemented = await operations.implementChange(job);
    job
      ..branchName = implemented.branchName
      ..changeSummary = implemented.summary
      ..phase = JobPhase.testing
      ..log('implemented on isolated branch ${implemented.branchName}');
    return job.phase;
  }

  bool _regressed(OptimisationJob job) {
    final before = job.baseline[job.targetMetric];
    final after = job.after?[job.targetMetric];
    if (before == null || after == null) {
      // Unmeasurable means unverifiable — fail closed, revert.
      return true;
    }
    final improved = job.higherIsBetter
        ? after >= before * (1 + minImprovementFraction)
        : after <= before * (1 - minImprovementFraction);
    return !improved;
  }

  OptimisationJob _byId(String jobId) {
    for (final j in jobs) {
      if (j.id == jobId) return j;
    }
    throw ArgumentError('Unknown optimisation job: $jobId');
  }

}

