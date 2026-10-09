import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/health.dart';

void main() {
  test('overall is the weighted mean of components that have data only', () {
    final report = HealthIndex().compute(const [
      ComponentHealth(
        component: HealthComponent.sessionResponsiveness,
        score: 0.8,
        detail: '',
      ),
      ComponentHealth(
        component: HealthComponent.apiReliability,
        score: 0.6,
        detail: '',
      ),
    ]);
    expect(report.overall, closeTo((0.8 * 0.20 + 0.6 * 0.15) / 0.35, 1e-9));
    expect(report.coverage, 0.25); // 2 of 8 components measured
  });

  test('missing measurements reduce coverage, never count as healthy', () {
    final report = HealthIndex().compute(const [
      ComponentHealth(
        component: HealthComponent.sessionResponsiveness,
        score: 1.0,
        detail: '',
      ),
      ComponentHealth.unavailable(
        HealthComponent.apiReliability,
        'no data',
      ),
    ]);
    expect(report.overall, 1.0);
    expect(report.coverage, 0.125); // 1 of 8
    final api = report.components
        .firstWhere((c) => c.component == HealthComponent.apiReliability);
    expect(api.score, isNull);
    expect(api.detail, 'no data');
  });

  test('with no data at all there is no score — not zero, not perfect', () {
    final report = HealthIndex().compute(const []);
    expect(report.overall, isNull);
    expect(report.coverage, 0.0);
  });

  test('scores are clamped to [0, 1] and custom weights are honoured', () {
    final report = HealthIndex(
      weights: const {HealthComponent.errorFrequency: 1.0},
    ).compute(const [
      ComponentHealth(
        component: HealthComponent.errorFrequency,
        score: 5.0, // out of range — clamped
        detail: '',
      ),
    ]);
    expect(report.overall, 1.0);
    expect(report.methodology, contains('weights'));
  });

  test('the published methodology string travels with the report', () {
    final report = HealthIndex().compute(const []);
    expect(report.methodology, contains('never count as healthy'));
  });
}
