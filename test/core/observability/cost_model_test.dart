import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/cost_model.dart';
import 'package:forge/core/observability/telemetry.dart';

void main() {
  test('configured pricing computes cost from measured token counts', () {
    final calc = CostCalculator();
    calc.configure('acme::big', inputUsdPerMTok: 3, outputUsdPerMTok: 6);
    final result = calc.estimate(
      providerId: 'acme',
      modelName: 'big',
      promptTokens: 2_000_000,
      completionTokens: 1_000_000,
      cachedPromptTokens: 0,
      modelIsFree: false,
    );
    expect(result.available, isTrue);
    expect(result.usd, 12.0); // 2M in × $3 + 1M out × $6
    expect(result.quality, MeasurementQuality.calculated);
  });

  test('cached prompt tokens are billed at the input rate once, not twice', () {
    final calc = CostCalculator();
    calc.configure('acme::big', inputUsdPerMTok: 3, outputUsdPerMTok: 6);
    final result = calc.estimate(
      providerId: 'acme',
      modelName: 'big',
      promptTokens: 1_000_000,
      completionTokens: 0,
      cachedPromptTokens: 500_000,
      modelIsFree: false,
    );
    expect(result.usd, 1.5); // only the 500k uncached input tokens billed
  });

  test('free-tier models cost zero when unconfigured — their actual charge', () {
    final calc = CostCalculator();
    final result = calc.estimate(
      providerId: 'nvidia-nim',
      modelName: 'llama-x',
      promptTokens: 1000,
      completionTokens: 100,
      cachedPromptTokens: 0,
      modelIsFree: true,
    );
    expect(result.available, isTrue);
    expect(result.usd, 0.0);
    expect(result.note, contains('Free-tier'));
  });

  test('unknown paid pricing is unavailable, never approximated', () {
    final calc = CostCalculator();
    final result = calc.estimate(
      providerId: 'acme',
      modelName: 'premium',
      promptTokens: 1000,
      completionTokens: 100,
      cachedPromptTokens: 0,
      modelIsFree: false,
    );
    expect(result.available, isFalse);
    expect(result.usd, isNull);
    expect(result.quality, MeasurementQuality.unavailable);
  });

  test('free models can be forced unavailable by configuration', () {
    final calc = CostCalculator(costFreeModelsAtZero: false);
    final result = calc.estimate(
      providerId: 'nvidia-nim',
      modelName: 'llama-x',
      promptTokens: 1000,
      completionTokens: 100,
      cachedPromptTokens: 0,
      modelIsFree: true,
    );
    expect(result.available, isFalse);
  });
}
