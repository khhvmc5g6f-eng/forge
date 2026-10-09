import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/anomaly.dart';

void main() {
  test('detects a latency spike against a stable baseline', () {
    final detector = AnomalyDetector();
    final window = <double>[100, 102, 98, 101, 99, 100, 103, 97, 100, 110.0];
    final anomaly = detector.evaluateSpike(metric: 'model.latencyMs', window: window);
    expect(anomaly, isNotNull);
    expect(anomaly!.severity, Severity.high);
    expect(anomaly.evidence['value'], 110);
    expect(anomaly.evidence['z'], greaterThan(3.5));
    expect(anomaly.status, AnomalyStatus.open);
  });

  test('an extreme spike is critical', () {
    final detector = AnomalyDetector();
    final window = <double>[100, 102, 98, 101, 99, 100, 103, 97, 100, 500.0];
    final anomaly = detector.evaluateSpike(metric: 'm', window: window);
    expect(anomaly!.severity, Severity.critical);
  });

  test('ordinary samples and short windows raise nothing', () {
    final detector = AnomalyDetector();
    final ordinary = <double>[100, 102, 98, 101, 99, 100, 103, 97, 100, 101];
    expect(detector.evaluateSpike(metric: 'm', window: ordinary), isNull);
    expect(
        detector.evaluateSpike(metric: 'm', window: <double>[1, 2, 3]), isNull);
  });

  test('a flat baseline has no robust scale and cannot judge spikes', () {
    final detector = AnomalyDetector();
    final window = <double>[100, 100, 100, 100, 100, 100, 100, 100, 100, 100];
    // MAD is zero; the detector stays silent rather than guessing.
    expect(detector.evaluateSpike(metric: 'm', window: window), isNull);
  });

  test('detects a sustained level shift against the pre-shift baseline', () {
    final detector = AnomalyDetector();
    final window = <double>[
      100, 101, 99, 100, 100, 102, 98, 100, // old half: ~100
      200, 201, 199, 200, 200, 202, 198, 200, // new half: ~200
    ];
    final anomaly = detector.evaluateLevelShift(metric: 'model.latencyMs', window: window);
    expect(anomaly, isNotNull);
    expect(anomaly!.evidence['oldMedian'], 100);
    expect(anomaly.evidence['newMedian'], 200);
    expect(anomaly.severity, Severity.high);
  });

  test('AlertCenter deduplicates, and supports the full alert lifecycle', () {
    final center = AlertCenter();
    final detector = AnomalyDetector();
    final window = <double>[100, 102, 98, 101, 99, 100, 103, 97, 100, 110.0];

    final first = detector.evaluateSpike(metric: 'm', window: window)!;
    center.add(first);
    // Same metric + same value while still open: not a second alert.
    final dup = detector.evaluateSpike(metric: 'm', window: window)!;
    center.add(dup);
    expect(center.active, hasLength(1));
    expect(center.all, hasLength(1));

    expect(center.acknowledge(first.id), isTrue);
    expect(center.active, isEmpty);
    expect(center.suppress(first.id), isTrue);
    expect(center.resolve(first.id), isTrue);
    expect(center.acknowledge('nonexistent'), isFalse);
  });
}
