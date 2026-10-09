import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/context_window.dart';

void main() {
  test('utilisation and remaining come from the latest observation', () {
    final tracker = ContextWindowTracker(capacityTokens: 1000);
    tracker.observe(250, 50, at: DateTime(2026, 1, 1));
    expect(tracker.utilisationFraction, 0.25);
    expect(tracker.remainingTokens, 750);
    expect(tracker.latest!.cachedTokens, 50);
  });

  test('no utilisation is reported before any observation', () {
    final tracker = ContextWindowTracker(capacityTokens: 1000);
    expect(tracker.utilisationFraction, isNull);
    expect(tracker.remainingTokens, isNull);
  });

  test('refuses to predict with fewer than five observations', () {
    final tracker = ContextWindowTracker(capacityTokens: 1000);
    final t0 = DateTime(2026, 1, 1);
    for (var i = 0; i < 4; i++) {
      tracker.observe(100 * (i + 1), 0, at: t0.add(Duration(minutes: i)));
    }
    final prediction = tracker.predictExhaustion();
    expect(prediction.eta, isNull);
    expect(prediction.confidence, PredictionConfidence.insufficientData);
  });

  test('predicts exhaustion from a linear growth trend, with confidence', () {
    final tracker = ContextWindowTracker(capacityTokens: 10000);
    final t0 = DateTime(2026, 1, 1);
    // Perfect linear growth: 1000 tokens per minute, 8 observations.
    for (var i = 0; i < 8; i++) {
      tracker.observe(1000 * (i + 1), 0, at: t0.add(Duration(minutes: i)));
    }
    final prediction = tracker.predictExhaustion();
    expect(prediction.eta, isNotNull);
    expect(prediction.tokensPerMinute, closeTo(1000, 1));
    // 2000 tokens remaining at 1000/min = 2 minutes.
    expect(prediction.eta!.inMinutes, 2);
    expect(prediction.confidence, PredictionConfidence.high);
    expect(prediction.reason, contains('R²=1.00'));
  });

  test('refuses to extrapolate a non-growing context', () {
    final tracker = ContextWindowTracker(capacityTokens: 10000);
    final t0 = DateTime(2026, 1, 1);
    for (var i = 0; i < 8; i++) {
      tracker.observe(2000, 0, at: t0.add(Duration(minutes: i)));
    }
    final prediction = tracker.predictExhaustion();
    expect(prediction.eta, isNull);
    expect(prediction.reason, contains('not growing'));
  });
}
