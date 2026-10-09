/// Neural Observatory — statistical anomaly detection and the alert
/// centre.
///
/// Deliberately simple, explainable statistics first: a robust (MAD-based)
/// z-score for point spikes and a split-window median comparison for level
/// shifts, both with explicit evidence. ML-based detection is only
/// justified "where the volume and quality of collected telemetry justify
/// it" per the spec — rolling MAD baselines are the honest starting point.
library;

enum Severity { info, warning, high, critical }

enum AnomalyStatus { open, acknowledged, suppressed, resolved }

class Anomaly {
  Anomaly({
    required this.id,
    required this.severity,
    required this.metric,
    required this.detectedAt,
    required this.evidence,
    required this.affected,
    required this.confidence,
    required this.probableCause,
    required this.recommendedInvestigation,
  });

  final String id;
  final Severity severity;
  final String metric;
  final DateTime detectedAt;

  /// The concrete numbers behind the call: observed value, baseline median
  /// and the robust deviation — an alert without evidence is a guess.
  final Map<String, double> evidence;

  final String affected;
  final double confidence;
  final String probableCause;
  final String recommendedInvestigation;

  AnomalyStatus status = AnomalyStatus.open;

  bool get isActive => status == AnomalyStatus.open;
}

/// Detects statistical anomalies in rolling windows.
class AnomalyDetector {
  AnomalyDetector({
    this.spikeSigma = 3.5,
    this.shiftSigma = 2.0,
    this.minBaselineSamples = 8,
  });

  /// Robust-z threshold for a single-sample spike (3.5 ≈ the conventional
  /// outlier cutoff for MAD-normalised deviation).
  final double spikeSigma;

  /// Threshold (in robust sigmas) for a sustained level shift between the
  /// two halves of the window.
  final double shiftSigma;

  final int minBaselineSamples;
  int _counter = 0;

  /// Evaluates the newest sample of [window] against the median/MAD
  /// baseline of everything before it. Returns null when the window is too
  /// short or the sample is unremarkable — silence is a real answer, not a
  /// failure to look.
  Anomaly? evaluateSpike({
    required String metric,
    required List<double> window,
    String? affected,
    String? probableCause,
    String? recommendedInvestigation,
  }) {
    if (window.length < minBaselineSamples + 1) return null;
    final baseline = window.sublist(0, window.length - 1);
    final value = window.last;
    final med = _median(baseline);
    final mad = _mad(baseline, med);
    if (mad == 0) return null; // Flat baseline — no robust scale to judge by.
    final robustSigma = mad * 1.4826;
    final z = (value - med).abs() / robustSigma;
    if (z < spikeSigma) return null;
    return Anomaly(
      id: 'anom_${DateTime.now().millisecondsSinceEpoch}_${_counter++}',
      severity: z >= 2 * spikeSigma ? Severity.critical : Severity.high,
      metric: metric,
      detectedAt: DateTime.now(),
      evidence: {
        'value': value,
        'baselineMedian': med,
        'robustSigma': robustSigma,
        'z': z,
      },
      affected: affected ?? metric,
      confidence: (z / (2 * spikeSigma)).clamp(0.0, 1.0),
      probableCause: probableCause ?? 'Deviation from rolling baseline.',
      recommendedInvestigation:
          recommendedInvestigation ?? 'Inspect the spans around the spike.',
    );
  }

  /// Detects a sustained shift: compares the median of the older half of
  /// the window with the newer half, in robust sigmas of the *pre-shift
  /// baseline* (the older half) — using the whole window's MAD would let
  /// a large shift inflate its own yardstick and hide itself.
  Anomaly? evaluateLevelShift({
    required String metric,
    required List<double> window,
    String? affected,
    String? probableCause,
    String? recommendedInvestigation,
  }) {
    if (window.length < 2 * minBaselineSamples) return null;
    final half = window.length ~/ 2;
    final oldHalf = window.sublist(0, half);
    final medOld = _median(oldHalf);
    final medNew = _median(window.sublist(half));
    final baselineMad = _mad(oldHalf, medOld);
    if (baselineMad == 0) return null;
    final z = (medNew - medOld).abs() / (baselineMad * 1.4826);
    if (z < shiftSigma) return null;
    return Anomaly(
      id: 'anom_${DateTime.now().millisecondsSinceEpoch}_${_counter++}',
      severity: z >= 2 * shiftSigma ? Severity.high : Severity.warning,
      metric: metric,
      detectedAt: DateTime.now(),
      evidence: {
        'oldMedian': medOld,
        'newMedian': medNew,
        'robustSigma': baselineMad * 1.4826,
        'z': z,
      },
      affected: affected ?? metric,
      confidence: (z / (2 * shiftSigma)).clamp(0.0, 1.0),
      probableCause:
          probableCause ?? 'Sustained level change versus earlier baseline.',
      recommendedInvestigation:
          recommendedInvestigation ?? 'Compare sessions before and after the shift.',
    );
  }

  static double _median(List<double> xs) {
    final sorted = xs.toList()..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static double _mad(List<double> xs, double med) {
    final devs = xs.map((x) => (x - med).abs()).toList()..sort();
    final mid = devs.length ~/ 2;
    return devs.length.isOdd ? devs[mid] : (devs[mid - 1] + devs[mid]) / 2;
  }
}

/// The alert inbox: anomaly lifecycle management (acknowledge, suppress,
/// resolve) — the spec requires alerts be more than a console print.
class AlertCenter {
  final List<Anomaly> _anomalies = [];

  List<Anomaly> get all => List<Anomaly>.unmodifiable(
      _anomalies..sort((a, b) => b.detectedAt.compareTo(a.detectedAt)));

  List<Anomaly> get active =>
      all.where((a) => a.status == AnomalyStatus.open).toList();

  void add(Anomaly anomaly) {
    // De-duplicate: a repeated identical metric+evidence signature does
    // not open a second alert while the first is still open.
    final dup = _anomalies.any((a) =>
        a.isActive &&
        a.metric == anomaly.metric &&
        a.evidence['value'] == anomaly.evidence['value']);
    if (!dup) _anomalies.add(anomaly);
  }

  bool acknowledge(String id) => _transition(id, AnomalyStatus.acknowledged);
  bool suppress(String id) => _transition(id, AnomalyStatus.suppressed);
  bool resolve(String id) => _transition(id, AnomalyStatus.resolved);

  bool _transition(String id, AnomalyStatus to) {
    for (final a in _anomalies) {
      if (a.id == id) {
        a.status = to;
        return true;
      }
    }
    return false;
  }
}

