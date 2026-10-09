import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/rolling_stats.dart';

void main() {
  test('RollingStats computes min/max/mean/percentiles correctly', () {
    final stats = RollingStats(window: 100);
    for (var i = 1; i <= 100; i++) {
      stats.add(i.toDouble());
    }
    expect(stats.count, 100);
    expect(stats.totalCount, 100);
    expect(stats.min, 1);
    expect(stats.max, 100);
    expect(stats.mean, 50.5);
    expect(stats.p50, closeTo(50.5, 1e-9)); // interpolated between 50 and 51
    expect(stats.p90, closeTo(90.1, 1e-9));
    expect(stats.p99, closeTo(99.01, 1e-9));
  });

  test('window evicts oldest samples and keeps totals', () {
    final stats = RollingStats(window: 10);
    for (var i = 1; i <= 20; i++) {
      stats.add(i.toDouble());
    }
    expect(stats.count, 10);
    expect(stats.totalCount, 20);
    expect(stats.last, 20);
    expect(stats.min, 11); // extremes recomputed after eviction
    expect(stats.max, 20);
  });

  test('moving average uses only the newest k samples', () {
    final stats = RollingStats(window: 100);
    for (var i = 1; i <= 10; i++) {
      stats.add(i.toDouble());
    }
    expect(stats.movingAverage(2), 9.5);
    expect(stats.movingAverage(3), 9);
    expect(stats.movingAverage(100), 5.5);
  });

  test('EWMA weights newer samples harder', () {
    final stats = RollingStats(window: 100);
    for (var i = 0; i < 10; i++) {
      stats.add(10.0);
    }
    stats.add(20.0);
    final ewma = stats.ewma(alpha: 0.5)!;
    expect(ewma, greaterThan(10));
    expect(ewma, lessThan(20));
  });

  test('trend detects rising and falling series', () {
    final rising = RollingStats(window: 100);
    for (var i = 1; i <= 30; i++) {
      rising.add(i.toDouble());
    }
    expect(rising.trend, TrendDirection.rising);

    final falling = RollingStats(window: 100);
    for (var i = 30; i >= 1; i--) {
      falling.add(i.toDouble());
    }
    expect(falling.trend, TrendDirection.falling);

    final flat = RollingStats(window: 100);
    for (var i = 0; i < 30; i++) {
      flat.add(50.0);
    }
    expect(flat.trend, TrendDirection.flat);
  });

  test('empty stats report null, not zero', () {
    final stats = RollingStats();
    expect(stats.last, isNull);
    expect(stats.mean, isNull);
    expect(stats.p95, isNull);
    expect(stats.snapshot()['p99'], isNull);
  });

  test('MetricSeries retains a bounded window and downsamples', () {
    final series = MetricSeries(window: 5, name: 'test');
    final base = DateTime(2026, 1, 1);
    for (var i = 0; i < 10; i++) {
      series.add(base.add(Duration(seconds: i)), i.toDouble());
    }
    expect(series.length, 5);
    expect(series.samples.first.value, 5);

    final downsampled = series.downsampleTo(2);
    expect(downsampled.length, 2);
  });

  test('MetricSeries.within returns only trailing samples', () {
    final series = MetricSeries(window: 100, name: 'test');
    final now = DateTime.now();
    series.add(now.subtract(const Duration(minutes: 10)), 1);
    series.add(now.subtract(const Duration(seconds: 30)), 2);
    final recent = series.within(const Duration(minutes: 1));
    expect(recent, hasLength(1));
    expect(recent.single.value, 2);
    expect(series.statsOf(const Duration(minutes: 1)).mean, 2);
  });
}
