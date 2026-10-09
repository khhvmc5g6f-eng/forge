import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/anomaly.dart';
import 'package:forge/core/observability/self_improvement.dart';

Anomaly testAnomaly() => Anomaly(
      id: 'anom_1',
      severity: Severity.high,
      metric: 'model.latencyMs',
      detectedAt: DateTime.now(),
      evidence: const {'value': 500, 'z': 5.0},
      affected: 'acme::big',
      confidence: 0.8,
      probableCause: 'slow path',
      recommendedInvestigation: 'profile it',
    );

class Recorder {
  final calls = <String>[];
}

SelfImprovementOperations ops(
  Recorder r, {
  bool testsPass = true,
  double benchmarkAfter = 250,
  String reviewVerdict = 'pass',
}) {
  return SelfImprovementOperations(
    implementChange: (job) async {
      r.calls.add('implement');
      return (branchName: 'ai/opt/${job.id}', summary: 'cache the lookup');
    },
    runTests: (job) async {
      r.calls.add('test');
      return (passed: testsPass, log: testsPass ? 'all green' : '1 failed');
    },
    runBenchmark: (job) async {
      r.calls.add('benchmark');
      return BenchmarkReading({'model.latencyMs': benchmarkAfter});
    },
    reviewChange: (job) async {
      r.calls.add('review');
      return reviewVerdict;
    },
    deployChange: (job) async => r.calls.add('deploy'),
    rollbackChange: (job) async => r.calls.add('rollback'),
  );
}

void main() {
  OptimisationJob propose(SelfImprovementEngine engine,
          {String target = 'lib/foo.dart'}) =>
      engine.proposeFromAnomaly(
        testAnomaly(),
        hypothesis: 'Cache the model lookup to cut P95 latency.',
        targetMetric: 'model.latencyMs',
        targetComponent: target,
        higherIsBetter: false,
        baselineMetrics: const {'model.latencyMs': 500},
      );

  test('observe mode collects only — proposing is refused outright', () {
    final r = Recorder();
    final engine = SelfImprovementEngine(ops(r), mode: AutonomyMode.observe);
    expect(() => propose(engine), throwsStateError);
    expect(r.calls, isEmpty);
  });

  test('investigate mode stops at the hypothesis — no code changes', () async {
    final r = Recorder();
    final engine =
        SelfImprovementEngine(ops(r), mode: AutonomyMode.investigate);
    final job = propose(engine);
    final phase = await engine.advance(job);
    expect(phase, JobPhase.hypothesisReady);
    expect(r.calls, isEmpty);
    expect(job.eventLog.last, contains('recommendation only'));
  });

  test('develop mode runs the full pipeline on an isolated branch, never deploys',
      () async {
    final r = Recorder();
    final engine = SelfImprovementEngine(ops(r), mode: AutonomyMode.develop);
    final job = propose(engine);

    expect((await engine.advance(job)).name, 'testing'); // implemented
    expect(job.branchName, startsWith('ai/opt/'));
    expect((await engine.advance(job)).name, 'benchmarking'); // tests passed
    expect((await engine.advance(job)).name, 'reviewing'); // 250 <= 495
    expect((await engine.advance(job)).name, 'readyToDeploy'); // review pass

    // Develop mode cannot deploy, no matter how often it advances.
    expect((await engine.advance(job)).name, 'readyToDeploy');
    expect(r.calls,
        containsAllInOrder(['implement', 'test', 'benchmark', 'review']));
    expect(r.calls, isNot(contains('deploy')));
    expect(job.eventLog.last, contains('mode is develop'));
  });

  test('a change whose tests fail is rolled back immediately', () async {
    final r = Recorder();
    final engine = SelfImprovementEngine(ops(r, testsPass: false),
        mode: AutonomyMode.develop);
    final job = propose(engine);
    await engine.advance(job); // implement
    final phase = await engine.advance(job); // test -> fail
    expect(phase, JobPhase.rolledBack);
    expect(r.calls, containsAll(['implement', 'test', 'rollback']));
    expect(job.eventLog.last, contains('tests failed'));
  });

  test('a change that regresses the measured metric is rolled back',
      () async {
    final r = Recorder();
    final engine = SelfImprovementEngine(ops(r, benchmarkAfter: 520),
        mode: AutonomyMode.develop); // 520 > 495 improvement target
    final job = propose(engine);
    await engine.advance(job);
    await engine.advance(job);
    final phase = await engine.advance(job); // benchmark -> regression
    expect(phase, JobPhase.rolledBack);
    expect(r.calls, contains('rollback'));
    expect(job.eventLog.last, contains('improvement criterion'));
  });

  test('a change the independent reviewer rejects is rolled back', () async {
    final r = Recorder();
    final engine = SelfImprovementEngine(
        ops(r, reviewVerdict: 'rework'),
        mode: AutonomyMode.develop);
    final job = propose(engine);
    for (var i = 0; i < 3; i++) {
      await engine.advance(job);
    }
    final phase = await engine.advance(job); // review -> rework
    expect(phase, JobPhase.rolledBack);
    expect(job.reviewVerdict, 'rework');
    expect(r.calls, contains('rollback'));
  });

  test('protected scopes stop cold without explicit authorisation', () async {
    final r = Recorder();
    final engine = SelfImprovementEngine(ops(r),
        mode: AutonomyMode.controlledAutonomy);
    final job = propose(engine, target: 'lib/core/tools/policy_engine.dart');

    expect(job.touchesProtectedScope, isTrue);
    final phase = await engine.advance(job);
    expect(phase, JobPhase.awaitingAuthorisation);
    expect(r.calls, isEmpty); // not even implemented yet
    expect((await engine.advance(job)).name, 'awaitingAuthorisation');

    engine.authorise(job.id);
    expect((await engine.advance(job)).name, 'testing'); // now implements
  });

  test('controlled autonomy deploys only an authorised, validated change',
      () async {
    final r = Recorder();
    final engine = SelfImprovementEngine(ops(r),
        mode: AutonomyMode.controlledAutonomy);
    final job = propose(engine);
    for (var i = 0; i < 4; i++) {
      await engine.advance(job);
    }
    // Pipeline complete; deployment still needs explicit authorisation.
    expect((await engine.advance(job)).name, 'readyToDeploy');
    expect(r.calls, isNot(contains('deploy')));
    expect(job.eventLog.last, contains('no explicit authorisation'));

    engine.authorise(job.id);
    expect((await engine.advance(job)).name, 'deployed');
    expect(r.calls, contains('deploy'));
  });

  test('an unmeasurable benchmark fails closed into rollback', () async {
    final r = Recorder();
    final engine = SelfImprovementEngine(_opsMissingMetric(r),
        mode: AutonomyMode.develop);
    final job = propose(engine);
    await engine.advance(job);
    await engine.advance(job);
    final phase = await engine.advance(job); // metric absent -> unverifiable
    expect(phase, JobPhase.rolledBack);
    expect(r.calls, contains('rollback'));
  });
}

SelfImprovementOperations _opsMissingMetric(Recorder r) {
  return SelfImprovementOperations(
    implementChange: (job) async => (branchName: 'ai/opt/x', summary: 's'),
    runTests: (job) async => (passed: true, log: 'ok'),
    runBenchmark: (job) async =>
        const BenchmarkReading({}), // target metric absent
    reviewChange: (job) async => 'pass',
    deployChange: (job) async => r.calls.add('deploy'),
    rollbackChange: (job) async => r.calls.add('rollback'),
  );
}

