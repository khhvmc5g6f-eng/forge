import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/token_rate.dart';

void main() {
  test('StreamRateAnalyzer measures TTFT, average and peak rate', () {
    final analyzer = StreamRateAnalyzer();
    final t0 = DateTime(2026, 1, 1);
    analyzer.start(at: t0);

    // An empty first chunk (keep-alive) must not count as a token.
    analyzer.tick(0, at: t0);
    expect(analyzer.timeToFirstToken, isNull);

    analyzer.tick(5, at: t0.add(const Duration(seconds: 1)));
    analyzer.tick(5, at: t0.add(const Duration(seconds: 2)));

    expect(analyzer.timeToFirstToken, const Duration(seconds: 1));
    expect(analyzer.totalTokens, 10);
    expect(analyzer.peakTokensPerSecond, 5);
    // Average spans first-token to last tick: 10 tokens / 1 second.
    expect(analyzer.averageTokensPerSecond, 10);
    expect(analyzer.stalls, isEmpty);
  });

  test('StreamRateAnalyzer detects stalls from chunk gaps', () {
    final analyzer = StreamRateAnalyzer(stallThreshold: const Duration(seconds: 2));
    final t0 = DateTime(2026, 1, 1);
    analyzer.start(at: t0);
    analyzer.tick(5, at: t0);
    // A 4-second gap before the next token-bearing chunk is a stall.
    analyzer.tick(5, at: t0.add(const Duration(seconds: 4)));
    expect(analyzer.stalls, hasLength(1));
    expect(analyzer.stalls.single, const Duration(seconds: 4));
  });

  test('ChatRequestRate is the whole-request average, null when not computable', () {
    final rate = ChatRequestRate.calculate(completionTokens: 100, latencyMs: 1000);
    expect(rate.tokensPerSecond, 100);

    final zeroTokens = ChatRequestRate.calculate(completionTokens: 0, latencyMs: 1000);
    expect(zeroTokens.tokensPerSecond, isNull);

    final zeroLatency = ChatRequestRate.calculate(completionTokens: 10, latencyMs: 0);
    expect(zeroLatency.tokensPerSecond, isNull);
  });
}
