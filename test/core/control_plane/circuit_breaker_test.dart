import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/control_plane/circuit_breaker.dart';
import 'package:forge/core/control_plane/circuit_breaker_registry.dart';

void main() {
  group('CircuitBreaker state machine', () {
    test('starts CLOSED and stays CLOSED on success', () {
      final breaker = CircuitBreaker('nvidia');
      breaker.recordSuccess();
      expect(breaker.state, CircuitState.closed);
      expect(breaker.isAvailable, isTrue);
    });

    test('escalates CLOSED -> DEGRADED -> OPEN on consecutive infra failures', () {
      final breaker = CircuitBreaker(
        'nvidia',
        config: const CircuitBreakerConfig(consecutiveFailuresToDegrade: 2, consecutiveFailuresToOpen: 4),
      );
      breaker.recordFailure(CircuitFailureType.serverError);
      expect(breaker.state, CircuitState.closed);
      breaker.recordFailure(CircuitFailureType.serverError);
      expect(breaker.state, CircuitState.degraded);
      breaker.recordFailure(CircuitFailureType.serverError);
      breaker.recordFailure(CircuitFailureType.serverError);
      expect(breaker.state, CircuitState.open);
      expect(breaker.isAvailable, isFalse);
    });

    test('429 (rate limited) counts as an infrastructure failure that can open the circuit', () {
      final breaker = CircuitBreaker(
        'nvidia',
        config: const CircuitBreakerConfig(consecutiveFailuresToDegrade: 1, consecutiveFailuresToOpen: 2),
      );
      breaker.recordFailure(CircuitFailureType.rateLimited);
      breaker.recordFailure(CircuitFailureType.rateLimited);
      expect(breaker.state, CircuitState.open);
      expect(breaker.total429s, 2);
    });

    test('model-quality and generated-code failures never open the circuit', () {
      final breaker = CircuitBreaker('nvidia::kimi-k3');
      for (var i = 0; i < 20; i++) {
        breaker.recordFailure(CircuitFailureType.generatedCodeFailure);
      }
      expect(breaker.state, CircuitState.closed);
      expect(breaker.isAvailable, isTrue);
      expect(breaker.totalFailures, 20); // still recorded, just doesn't affect availability
    });

    test('OPEN transitions to HALF_OPEN only after the cooldown elapses', () async {
      final breaker = CircuitBreaker(
        'nvidia',
        config: const CircuitBreakerConfig(
          consecutiveFailuresToDegrade: 1,
          consecutiveFailuresToOpen: 1,
          openCooldown: Duration(milliseconds: 50),
        ),
      );
      breaker.recordFailure(CircuitFailureType.serverError);
      expect(breaker.state, CircuitState.open);
      expect(breaker.isAvailable, isFalse); // still within cooldown

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(breaker.isAvailable, isTrue); // cooldown elapsed -> HALF_OPEN, which is available
      expect(breaker.state, CircuitState.halfOpen);
    });

    test('a successful probe in HALF_OPEN moves to RECOVERING, then CLOSED after enough successes', () async {
      final breaker = CircuitBreaker(
        'nvidia',
        config: const CircuitBreakerConfig(
          consecutiveFailuresToDegrade: 1,
          consecutiveFailuresToOpen: 1,
          openCooldown: Duration(milliseconds: 10),
          successesToRecoverFromHalfOpen: 1,
          successesToCloseFromRecovering: 2,
        ),
      );
      breaker.recordFailure(CircuitFailureType.serverError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(breaker.state, CircuitState.halfOpen);

      breaker.recordSuccess();
      expect(breaker.state, CircuitState.recovering);

      breaker.recordSuccess();
      expect(breaker.state, CircuitState.recovering); // 1 of 2 required
      breaker.recordSuccess();
      expect(breaker.state, CircuitState.closed);
    });

    test('a failed probe during HALF_OPEN goes straight back to OPEN, not DEGRADED', () async {
      final breaker = CircuitBreaker(
        'nvidia',
        config: const CircuitBreakerConfig(
          consecutiveFailuresToDegrade: 1,
          consecutiveFailuresToOpen: 1,
          openCooldown: Duration(milliseconds: 10),
        ),
      );
      breaker.recordFailure(CircuitFailureType.timeout);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(breaker.state, CircuitState.halfOpen);

      breaker.recordFailure(CircuitFailureType.timeout);
      expect(breaker.state, CircuitState.open);
    });

    test('a regression during RECOVERING goes back to OPEN', () async {
      final breaker = CircuitBreaker(
        'nvidia',
        config: const CircuitBreakerConfig(
          consecutiveFailuresToDegrade: 1,
          consecutiveFailuresToOpen: 1,
          openCooldown: Duration(milliseconds: 10),
          successesToRecoverFromHalfOpen: 1,
        ),
      );
      breaker.recordFailure(CircuitFailureType.serverError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      breaker.recordSuccess(); // -> recovering
      expect(breaker.state, CircuitState.recovering);

      breaker.recordFailure(CircuitFailureType.serverError);
      expect(breaker.state, CircuitState.open);
    });

    test('manualOpen/manualClose override automatic state', () {
      final breaker = CircuitBreaker('nvidia');
      breaker.manualOpen();
      expect(breaker.state, CircuitState.open);
      breaker.recordSuccess(); // does not auto-heal a manual open
      breaker.manualClose();
      expect(breaker.state, CircuitState.closed);
    });

    test('healthScore reflects both success rate and state', () {
      final breaker = CircuitBreaker('nvidia');
      for (var i = 0; i < 9; i++) {
        breaker.recordSuccess();
      }
      breaker.recordFailure(CircuitFailureType.generatedCodeFailure);
      expect(breaker.healthScore, closeTo(0.9, 0.01)); // still closed, 90% success
    });
  });

  group('CircuitBreakerRegistry', () {
    test('breakerFor creates and reuses the same instance per id', () {
      final registry = CircuitBreakerRegistry();
      final a = registry.breakerFor('nvidia::kimi-k3');
      final b = registry.breakerFor('nvidia::kimi-k3');
      expect(identical(a, b), isTrue);
    });

    test('rankAvailable excludes OPEN circuits and ranks the rest by health', () {
      final registry = CircuitBreakerRegistry(
        defaultConfig: const CircuitBreakerConfig(consecutiveFailuresToDegrade: 1, consecutiveFailuresToOpen: 1),
      );
      registry.breakerFor('good')..recordSuccess()..recordSuccess();
      registry.breakerFor('mediocre')
        ..recordSuccess()
        ..recordFailure(CircuitFailureType.generatedCodeFailure); // still closed, lower score
      registry.breakerFor('down').recordFailure(CircuitFailureType.serverError); // opens

      final ranked = registry.rankAvailable(['good', 'mediocre', 'down']);
      expect(ranked.map((b) => b.id), ['good', 'mediocre']);
    });

    test('resetAll closes every circuit and clears statistics', () {
      final registry = CircuitBreakerRegistry(
        defaultConfig: const CircuitBreakerConfig(consecutiveFailuresToDegrade: 1, consecutiveFailuresToOpen: 1),
      );
      registry.breakerFor('nvidia').recordFailure(CircuitFailureType.serverError);
      expect(registry.breakerFor('nvidia').state, CircuitState.open);

      registry.resetAll();
      expect(registry.breakerFor('nvidia').state, CircuitState.closed);
      expect(registry.breakerFor('nvidia').totalFailures, 0);
    });
  });
}
