/// Neural Observatory — cost accounting.
///
/// Cost here is arithmetic over *configured* prices, never a measurement:
/// the quality label on every cost figure is [MeasurementQuality.calculated]
/// when a price is configured for the model, and [MeasurementQuality.unavailable]
/// otherwise. There is deliberately **no built-in price table for paid
/// models** — stale or guessed prices would be exactly the kind of fiction
/// the Observatory forbids. Free-tier models (per the registry's `isFree`)
/// are costed at $0 with an explicit note, because $0 is what the API
/// charges, not a guess.
library;

import 'telemetry.dart';

/// Where a price came from.
enum PricingSource {
  /// Explicitly configured by the operator (Settings/`CostCalculator.configure`).
  configured,

  /// The registry marks this model free-tier; $0 is the actual charge.
  freeTier,
}

class ModelPricing {
  const ModelPricing({
    required this.inputUsdPerMTok,
    required this.outputUsdPerMTok,
    required this.source,
  });

  final double inputUsdPerMTok;
  final double outputUsdPerMTok;
  final PricingSource source;
}

class CostResult {
  const CostResult({required this.usd, required this.quality, required this.note});

  const CostResult.unavailable()
      : usd = null,
        quality = MeasurementQuality.unavailable,
        note = 'No pricing configured for this model.';

  final double? usd;
  final MeasurementQuality quality;
  final String note;

  bool get available => usd != null;
}

class CostCalculator {
  CostCalculator({
    Map<String, ModelPricing>? configuredPricing,
    this.costFreeModelsAtZero = true,
  }) : _pricing = Map<String, ModelPricing>.of(configuredPricing ?? const {});

  final Map<String, ModelPricing> _pricing;

  /// Free-tier models (per the registry's `isFree`) are costed at $0 when
  /// no explicit pricing is configured — $0 is their actual API charge,
  /// not a guess.
  final bool costFreeModelsAtZero;

  /// Registers exact `provider::model` pricing (USD per 1M tokens). Cache
  /// reads are billed at the input rate in this simple model; a provider
  /// with distinct cached pricing can be configured the same way once its
  /// wire format is observed.
  void configure(String modelKey, {required double inputUsdPerMTok, required double outputUsdPerMTok}) {
    _pricing[modelKey] = ModelPricing(
      inputUsdPerMTok: inputUsdPerMTok,
      outputUsdPerMTok: outputUsdPerMTok,
      source: PricingSource.configured,
    );
  }

  CostResult estimate({
    required String providerId,
    required String modelName,
    required int promptTokens,
    required int completionTokens,
    required int cachedPromptTokens,
    required bool modelIsFree,
  }) {
    final exact = _pricing['$providerId::$modelName'];
    if (exact != null) {
      return _compute(exact, promptTokens, completionTokens, cachedPromptTokens);
    }
    if (costFreeModelsAtZero && modelIsFree) {
      return CostResult(
        usd: 0.0,
        quality: MeasurementQuality.calculated,
        note: 'Free-tier model — no API charge.',
      );
    }
    return const CostResult.unavailable();
  }

  CostResult _compute(
    ModelPricing pricing,
    int promptTokens,
    int completionTokens,
    int cachedTokens,
  ) {
    final billableInput = promptTokens - cachedTokens < 0 ? 0 : promptTokens - cachedTokens;
    final usd = (billableInput / 1e6) * pricing.inputUsdPerMTok +
        (completionTokens / 1e6) * pricing.outputUsdPerMTok;
    return CostResult(
      usd: usd,
      quality: MeasurementQuality.calculated,
      note: 'From ${pricing.source == PricingSource.configured ? 'configured' : 'free-tier'} pricing.',
    );
  }
}
