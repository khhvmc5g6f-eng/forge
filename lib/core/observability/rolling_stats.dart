/// Neural Observatory — rolling statistics and time series.
///
/// Every live metric in the Observatory renders through these: current
/// value, min/max, mean, median, P50/P90/P95/P99, moving averages, and
/// trend direction over a bounded window. Pure Dart, no dependencies.
library;

/// Direction of the recent trend of a series, judged by comparing the mean
/// of the newest third of the window with the oldest third.
enum TrendDirection { flat, rising, falling }

/// Bounded-window descriptive statistics. The window is a ring of the most
/// recent samples; every statistic is computed on demand over that window,
/// so `add` is O(1) amortised and memory is bounded by [window].
class RollingStats {
  RollingStats({this.window = 256});

  /// Maximum samples retained. 256 covers ~4 minutes at one sample/second
  /// — enough for a live panel without unbounded growth.
  final int window;

  final List<double> _samples = [];
  double _min = double.infinity;
  double _max = double.negativeInfinity;
  double _sum = 0;

  /// Total samples ever added (not truncated by the window).
  int totalCount = 0;

  int get count => _samples.length;

  double? get last => _samples.isEmpty ? null : _samples.last;

  double? get min => _samples.isEmpty ? null : _min;

  double? get max => _samples.isEmpty ? null : _max;

  double? get mean => _samples.isEmpty ? null : _sum / _samples.length;

  void add(double value) {
    _samples.add(value);
    _sum += value;
    totalCount++;
    if (value < _min) _min = value;
    if (value > _max) _max = value;
    if (_samples.length > window) {
      final evicted = _samples.removeAt(0);
      _sum -= evicted;
      if (evicted == _min || evicted == _max) _recomputeExtremes();
    }
  }

  void _recomputeExtremes() {
    _min = double.infinity;
    _max = double.negativeInfinity;
    for (final s in _samples) {
      if (s < _min) _min = s;
      if (s > _max) _max = s;
    }
  }

  /// Linear-interpolation percentile of the current window, `q` in
  /// [0, 1] — P50 of an even-sized window lands between the two middle
  /// samples, matching the standard (numpy-style) definition rather
  /// than nearest-rank jumps.
  double? percentile(double q) {
    if (_samples.isEmpty) return null;
    final sorted = _samples.toList()..sort();
    if (sorted.length == 1) return sorted[0];
    final pos = q * (sorted.length - 1);
    final lo = pos.floor();
    final hi = pos.ceil();
    return sorted[lo] + (pos - lo) * (sorted[hi] - sorted[lo]);
  }

  double? get median => percentile(0.5);
  double? get p50 => percentile(0.5);
  double? get p90 => percentile(0.90);
  double? get p95 => percentile(0.95);
  double? get p99 => percentile(0.99);

  /// Arithmetic mean of the newest `k` samples (simple moving average).
  double? movingAverage(int k) {
    if (_samples.isEmpty) return null;
    final take = k < 1 ? 1 : (k > _samples.length ? _samples.length : k);
    var sum = 0.0;
    for (var i = _samples.length - take; i < _samples.length; i++) {
      sum += _samples[i];
    }
    return sum / take;
  }

  /// Exponentially weighted moving average; `alpha` in (0, 1], higher
  /// weights newer samples harder.
  double? ewma({double alpha = 0.3}) {
    if (_samples.isEmpty) return null;
    var acc = _samples.first;
    for (var i = 1; i < _samples.length; i++) {
      acc = alpha * _samples[i] + (1 - alpha) * acc;
    }
    return acc;
  }

  /// Compares the mean of the newest third of the window against the
  /// oldest third, with a 5% dead-band so noise reads as [TrendDirection.flat].
  TrendDirection get trend {
    if (_samples.length < 6) return TrendDirection.flat;
    final third = _samples.length ~/ 3;
    var oldSum = 0.0;
    for (var i = 0; i < third; i++) {
      oldSum += _samples[i];
    }
    var newSum = 0.0;
    for (var i = _samples.length - third; i < _samples.length; i++) {
      newSum += _samples[i];
    }
    final oldMean = oldSum / third;
    final newMean = newSum / third;
    final band = oldMean.abs() * 0.05;
    if (newMean > oldMean + band) return TrendDirection.rising;
    if (newMean < oldMean - band) return TrendDirection.falling;
    return TrendDirection.flat;
  }

  /// Compact snapshot for UI/serialisation: only the values a panel shows.
  Map<String, double?> snapshot() => <String, double?>{
        'last': last,
        'min': min,
        'max': max,
        'mean': mean,
        'median': median,
        'p90': p90,
        'p95': p95,
        'p99': p99,
      };
}

/// One timestamped numeric sample.
class TimedSample {
  const TimedSample(this.at, this.value);
  final DateTime at;
  final double value;
}

/// A bounded, timestamped series — the storage behind every live graph
/// and every rolling baseline. Also supports downsampling for long-range
/// views so a 24-hour chart does not need every raw second.
class MetricSeries {
  MetricSeries({this.window = 2048, String? name}) : name = name ?? 'unnamed';

  final String name;
  final int window;

  final List<TimedSample> _samples = [];

  int get length => _samples.length;

  List<TimedSample> get samples => List<TimedSample>.unmodifiable(_samples);

  /// Newest sample value; null when the series is empty (never zero).
  double? get last => _samples.isEmpty ? null : _samples.last.value;

  void add(DateTime at, double value) {
    _samples.add(TimedSample(at, value));
    if (_samples.length > window) _samples.removeAt(0);
  }

  /// Samples inside the trailing [duration]; the input to [RollingStats]
  /// for "last N minutes" panels and anomaly baselines.
  List<TimedSample> within(Duration duration) {
    final cutoff = DateTime.now().subtract(duration);
    final first = _samples.indexWhere((s) => s.at.isAfter(cutoff));
    return first <= 0
        ? List<TimedSample>.of(_samples)
        : _samples.sublist(first);
  }

  /// Descriptive statistics over the trailing [duration].
  RollingStats statsOf(Duration duration) {
    final stats = RollingStats(window: window);
    for (final s in within(duration)) {
      stats.add(s.value);
    }
    return stats;
  }

  /// Averages samples into at most [buckets] equal-width buckets across the
  /// whole retained range — the downsampling step that keeps long-range
  /// reporting bounded (a retention/visualisation policy: raw samples stay
  /// in the JSONL store, this only affects the rendered series).
  List<TimedSample> downsampleTo(int buckets) {
    if (buckets >= _samples.length || _samples.isEmpty) return samples;
    final out = <TimedSample>[];
    final per = (_samples.length / buckets).ceil();
    for (var i = 0; i < _samples.length; i += per) {
      var sum = 0.0;
      var n = 0;
      var lastAt = _samples[i].at;
      for (var j = i; j < i + per && j < _samples.length; j++) {
        sum += _samples[j].value;
        lastAt = _samples[j].at;
        n++;
      }
      out.add(TimedSample(lastAt, sum / n));
    }
    return out;
  }
}

