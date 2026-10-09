/// Neural Observatory — context-window utilisation and exhaustion
/// prediction.
///
/// The gauge itself is provider-reported token counts over the model's
/// declared capacity. The exhaustion prediction is an ordinary least-
/// squares projection of the observed growth trend — [MeasurementQuality.estimated],
/// always rendered with its confidence, and never produced when the trend
/// is not actually rising.
library;

import 'telemetry.dart';

class ContextObservation {
  const ContextObservation(this.at, this.usedTokens, this.cachedTokens);
  final DateTime at;
  final int usedTokens;
  final int cachedTokens;
}

enum PredictionConfidence { insufficientData, low, medium, high }

class ContextExhaustionPrediction {
  const ContextExhaustionPrediction({
    required this.eta,
    required this.tokensPerMinute,
    required this.confidence,
    required this.reason,
  });

  const ContextExhaustionPrediction.none(this.reason)
      : eta = null,
        tokensPerMinute = 0,
        confidence = PredictionConfidence.insufficientData;

  final Duration? eta;
  final double tokensPerMinute;
  final PredictionConfidence confidence;
  final String reason;
}

/// Tracks the context window of one session (the conversation's own
/// context, distinct from the model provider's server-side cache).
class ContextWindowTracker {
  ContextWindowTracker({required this.capacityTokens, this.maxObservations = 200});

  final int capacityTokens;
  final int maxObservations;

  final List<ContextObservation> _observations = [];

  ContextObservation? get latest =>
      _observations.isEmpty ? null : _observations.last;

  /// Used (prompt-side) tokens / capacity, 0..1. `null` before any
  /// observation — an unobserved context is never reported as 0%.
  double? get utilisationFraction {
    final l = latest;
    if (l == null || capacityTokens <= 0) return null;
    return (l.usedTokens / capacityTokens).clamp(0.0, 1.0);
  }

  int? get remainingTokens {
    final l = latest;
    if (l == null) return null;
    final r = capacityTokens - l.usedTokens;
    return r < 0 ? 0 : r;
  }

  void observe(int usedTokens, int cachedTokens, {DateTime? at}) {
    _observations.add(ContextObservation(at ?? DateTime.now(), usedTokens, cachedTokens));
    if (_observations.length > maxObservations) _observations.removeAt(0);
  }

  /// Least-squares slope of used-tokens over minutes, plus R².
  (double, double) _trend() {
    if (_observations.length < 2) return (0.0, 0.0);
    final t0 = _observations.first.at;
    final xs = _observations
        .map((o) => o.at.difference(t0).inMicroseconds / 6e7)
        .toList();
    final ys = _observations.map((o) => o.usedTokens.toDouble()).toList();
    final n = xs.length.toDouble();
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;
    var num = 0.0, denX = 0.0, denY = 0.0;
    for (var i = 0; i < xs.length; i++) {
      num += (xs[i] - mx) * (ys[i] - my);
      denX += (xs[i] - mx) * (xs[i] - mx);
      denY += (ys[i] - my) * (ys[i] - my);
    }
    final slope = denX == 0 ? 0.0 : num / denX;
    final r2 = denX == 0 || denY == 0 ? 0.0 : (num * num) / (denX * denY);
    return (slope, r2);
  }

  /// Projects when the context window will exhaust, from the observed
  /// consumption trend. Discloses confidence from sample count and fit
  /// quality; refuses to extrapolate a non-rising trend.
  ContextExhaustionPrediction predictExhaustion() {
    final l = latest;
    if (l == null || capacityTokens <= 0) {
      return const ContextExhaustionPrediction.none('No context observations yet.');
    }
    final n = _observations.length;
    if (n < 5) {
      return const ContextExhaustionPrediction.none(
          'Fewer than 5 observations — trend not yet established.');
    }
    final (slope, r2) = _trend();
    if (slope <= 0) {
      return const ContextExhaustionPrediction.none('Context is not growing.');
    }
    final remaining = capacityTokens - l.usedTokens;
    if (remaining <= 0) {
      return const ContextExhaustionPrediction.none('Context window already exhausted.');
    }
    final minutes = remaining / slope;
    final confidence = n >= 8 && r2 >= 0.8
        ? PredictionConfidence.high
        : r2 >= 0.5
            ? PredictionConfidence.medium
            : PredictionConfidence.low;
    return ContextExhaustionPrediction(
      eta: Duration(milliseconds: (minutes * 60 * 1000).round()),
      tokensPerMinute: slope,
      confidence: confidence,
      reason: 'OLS trend over $n observations (R²=${r2.toStringAsFixed(2)}).',
    );
  }
}
