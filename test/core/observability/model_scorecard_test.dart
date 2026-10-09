import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/model_scorecard.dart';

void main() {
  ModelScorecard freeCard() {
    final card = ModelScorecard(
        providerId: 'nvidia-nim', modelName: 'free-a', freeTier: true);
    for (var i = 0; i < 5; i++) {
      card.recordRequest(
        latencyMs: 100 * (i + 1),
        tokensPerSecond: 10,
        succeeded: true,
        promptTokens: 1000,
        completionTokens: 100,
        costUsd: 0.0,
      );
    }
    return card;
  }

  ModelScorecard paidCard() {
    final card = ModelScorecard(providerId: 'acme', modelName: 'paid-b');
    for (var i = 0; i < 5; i++) {
      card.recordRequest(
        latencyMs: 1000,
        tokensPerSecond: 20,
        succeeded: true,
        promptTokens: 2000,
        completionTokens: 200,
        costUsd: 0.5,
      );
    }
    return card;
  }

  test('scorecards accumulate real request outcomes', () {
    final card = freeCard();
    expect(card.requests, 5);
    expect(card.failures, 0);
    expect(card.successRate, 1.0);
    expect(card.promptTokens, 5000);
    expect(card.completionTokens, 500);
    expect(card.latencyMs.p95, closeTo(480, 0.01)); // interpolated 3.8th of [100..500]
    expect(card.tokensPerSecond.mean, 10);
    expect(card.costUsd, 0.0);
  });

  test('failed requests and rate limits feed reliability honestly', () {
    final card = ModelScorecard(providerId: 'p', modelName: 'm');
    card
      ..recordRequest(
          latencyMs: 100,
          succeeded: true,
          promptTokens: 10,
          completionTokens: 5)
      ..recordRequest(
          latencyMs: 100,
          succeeded: false,
          rateLimited: true,
          promptTokens: 10,
          completionTokens: 0);
    expect(card.successRate, 0.5);
    expect(card.rateLimited, 1);
  });

  test('efficiency score: cheaper-and-faster wins on default weights', () {
    final comparison = ModelComparison.compute([freeCard(), paidCard()]);
    final byKey = {for (final s in comparison.scores) s.modelKey: s};
    final freeScore = byKey['nvidia-nim::free-a']!;
    final paidScore = byKey['acme::paid-b']!;

    expect(freeScore.sufficientData, isTrue);
    expect(paidScore.sufficientData, isTrue);
    // Relative normalisation inside the compared set.
    expect(freeScore.components['cost']!.value, 1.0);
    expect(paidScore.components['cost']!.value, 0.0);
    expect(freeScore.components['speed']!.value, 0.5);
    expect(paidScore.components['speed']!.value, 1.0);
    expect(freeScore.value!, greaterThan(paidScore.value!));
    expect(comparison.methodology, contains('administrator-adjustable'));
  });

  test('models with too few requests are flagged insufficient-data', () {
    final thin = ModelScorecard(providerId: 'p', modelName: 'thin');
    thin.recordRequest(
        latencyMs: 100, succeeded: true, promptTokens: 1, completionTokens: 1);
    final comparison = ModelComparison.compute([thin]);
    expect(comparison.scores.single.sufficientData, isFalse);
    expect(comparison.scores.single.sampleSize, 1);
  });

  test('cost without configured pricing is excluded, not guessed', () {
    final unknownCost = ModelScorecard(providerId: 'p', modelName: 'u');
    unknownCost.recordRequest(
        latencyMs: 100,
        succeeded: true,
        promptTokens: 10,
        completionTokens: 10,
        costUsd: null);
    final comparison = ModelComparison.compute([unknownCost]);
    expect(comparison.scores.single.components['cost']!.available, isFalse);
  });
}
