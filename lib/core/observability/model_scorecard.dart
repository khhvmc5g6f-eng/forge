/// Neural Observatory — per-model live scorecards and the composite
/// Neural Model Efficiency Score.
///
/// Every figure is accumulated from real request spans: latency, TTFT
/// (streaming only), whole-request tokens/sec, error and rate-limit
/// counts, and cost from configured pricing. "Faster tokens ≠ better
/// model" is enforced structurally: speed is one configurable component of
/// the composite, never the ranking itself.
library;

import 'rolling_stats.dart';

/// Live comparison row for one model, accumulated across sessions.
class ModelScorecard {
  ModelScorecard({
    required this.providerId,
    required this.modelName,
    this.freeTier = false,
  })  : latencyMs = RollingStats(window: 512),
        ttftMs = RollingStats(window: 512),
        tokensPerSecond = RollingStats(window: 512);

  final String providerId;
  final String modelName;
  final bool freeTier;

  final RollingStats latencyMs;
  final RollingStats ttftMs;
  final RollingStats tokensPerSecond;

  int requests = 0;
  int failures = 0;
  int rateLimited = 0;
  int promptTokens = 0;
  int completionTokens = 0;

  /// Accumulated cost; null when any contributing request had no
  /// configured pricing — an unknown price is never approximated.
  double? costUsd;
  bool costHasUnknown = false;

  String get key => '$providerId::$modelName';

  int get totalTokens => promptTokens + completionTokens;

  double get successRate =>
      requests == 0 ? 0 : (requests - failures) / requests;

  void recordRequest({
    required int latencyMs,
    int? ttftMs,
    double? tokensPerSecond,
    required bool succeeded,
    bool rateLimited = false,
    required int promptTokens,
    required int completionTokens,
    double? costUsd,
  }) {
    requests++;
    this.latencyMs.add(latencyMs.toDouble());
    if (ttftMs != null) this.ttftMs.add(ttftMs.toDouble());
    if (tokensPerSecond != null) this.tokensPerSecond.add(tokensPerSecond);
    if (!succeeded) failures++;
    if (rateLimited) this.rateLimited++;
    this.promptTokens += promptTokens;
    this.completionTokens += completionTokens;
    if (costUsd == null) {
      costHasUnknown = true;
    } else {
      // `this.` matters here: the parameter shadows the field.
      this.costUsd = (this.costUsd ?? 0) + costUsd;
    }
  }
}

/// Configurable component weights of the efficiency score. Defaults are
/// published in the methodology string so the number is always
/// reproducible by hand from the table beside it.
class EfficiencyWeights {
  const EfficiencyWeights({
    this.quality = 0.35,
    this.reliability = 0.20,
    this.latency = 0.15,
    this.cost = 0.15,
    this.speed = 0.15,
  });

  final double quality;
  final double reliability;
  final double latency;
  final double cost;
  final double speed;

  double get total => quality + reliability + latency + cost + speed;
}

class EfficiencyScore {
  const EfficiencyScore({
    required this.modelKey,
    required this.value,
    required this.sufficientData,
    required this.sampleSize,
    required this.components,
    required this.methodology,
  });

  final String modelKey;

  /// Composite 0..1, or null when no component had data.
  final double? value;

  /// False below minSamples — the UI renders low-sample scores as
  /// "insufficient data", never as a confident ranking.
  final bool sufficientData;
  final int sampleSize;

  /// Component name → (normalised 0..1, available). Unavailable components
  /// (e.g. cost without configured pricing) are excluded and reported.
  final Map<String, ({double value, bool available})> components;
  final String methodology;
}

class ModelComparison {
  const ModelComparison._(this.scores, this.methodology);

  final List<EfficiencyScore> scores;
  final String methodology;

  static const String _methodologyText =
      'Efficiency = Σ(wᵢ·cᵢ)/Σ(wᵢ) over available components. quality = '
      'success rate; reliability = success rate × (1 − 0.5·rateLimitShare); '
      'latency = 1 − clamp(p95ms/targetMs, 0, 1); cost = cheapestCost/modelCost '
      '(0-cost models score 1); speed = model tokens-per-sec ÷ fastest '
      'tokens-per-sec. Weights (default): quality .35, reliability .20, '
      'latency .15, cost .15, speed .15 — administrator-adjustable. Models '
      'with fewer than minSamples requests are flagged insufficient-data.';

  /// Computes scores for every scorecard. Normalisation of cost and speed
  /// is relative to the compared set — the method note says so, and the
  /// note travels with the result.
  static ModelComparison compute(
    List<ModelScorecard> cards, {
    EfficiencyWeights weights = const EfficiencyWeights(),
    int latencyTargetMs = 30000,
    int minSamples = 5,
  }) {
    final anyCost =
        cards.any((c) => !c.costHasUnknown && (c.costUsd ?? 0) > 0);
    final cheapest = anyCost
        ? cards
            .where((c) => !c.costHasUnknown)
            .map((c) => c.costUsd ?? 0)
            .reduce((a, b) => a < b ? a : b)
        : null;
    final fastestTps = cards
        .map((c) => c.tokensPerSecond.mean)
        .whereType<double>()
        .fold<double?>(null, (best, v) => best == null || v > best ? v : best);

    final scores = cards.map((c) {
      final components = <String, ({double value, bool available})>{};

      components['quality'] =
          (value: c.successRate, available: c.requests > 0);
      final rlShare = c.requests == 0 ? 0.0 : c.rateLimited / c.requests;
      components['reliability'] = (
        value: c.successRate * (1 - 0.5 * rlShare),
        available: c.requests > 0,
      );
      final p95 = c.latencyMs.p95;
      components['latency'] = (
        value: p95 == null
            ? 0.0
            : 1 - ((p95 / latencyTargetMs).clamp(0.0, 1.0)),
        available: p95 != null,
      );
      final cost = c.costUsd;
      components['cost'] = (
        value: (cost == null || cheapest == null || cost == 0)
            ? 1.0
            : cheapest / cost,
        available: cost != null && !c.costHasUnknown && cheapest != null,
      );
      final tps = c.tokensPerSecond.mean;
      components['speed'] = (
        value: (tps == null || fastestTps == null) ? 0.0 : tps / fastestTps,
        available: tps != null && fastestTps != null,
      );

      var wsum = 0.0;
      var acc = 0.0;
      void weigh(String name, double w) {
        final comp = components[name]!;
        if (!comp.available) return;
        wsum += w;
        acc += comp.value.clamp(0.0, 1.0) * w;
      }

      weigh('quality', weights.quality);
      weigh('reliability', weights.reliability);
      weigh('latency', weights.latency);
      weigh('cost', weights.cost);
      weigh('speed', weights.speed);

      return EfficiencyScore(
        modelKey: c.key,
        value: wsum == 0 ? null : acc / wsum,
        sufficientData: c.requests >= minSamples,
        sampleSize: c.requests,
        components: components,
        methodology: _methodologyText,
      );
    }).toList();

    return ModelComparison._(scores, _methodologyText);
  }
}

