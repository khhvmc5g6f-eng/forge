import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/models/model_provider.dart';
import 'package:forge/core/review/review_package.dart';
import 'package:forge/core/review/reviewer.dart';

import '../../support/fake_model_provider.dart';

ReviewPackage samplePackage() => const ReviewPackage(
      taskTitle: 'Fix Cockpit CPU spike',
      originalProblem: 'Cockpit Core consumes excessive CPU on AIR3.',
      requirements: 'CPU usage returns to baseline; no dropped frames.',
      implementationSummary: 'Removed duplicate listener registration.',
      architecturalChanges: '',
      diff: '--- a/lib/cockpit.dart\n+++ b/lib/cockpit.dart\n',
      filesChanged: ['lib/cockpit.dart'],
      testsRun: ['flutter test test/cockpit_test.dart'],
      buildResultSummary: 'flutter build succeeded',
    );

void main() {
  group('ModelReviewer', () {
    test('parses an explicit PASS verdict', () async {
      final provider = FakeModelProvider('anthropic');
      provider.enqueue(textResponse('Looks good.\nVERDICT: PASS'));
      final reviewer = ModelReviewer(reviewerId: 'claude-final', provider: provider, modelName: 'claude-sonnet-5');

      final verdict = await reviewer.review(samplePackage());
      expect(verdict.outcome, ReviewOutcome.pass);
      expect(verdict.requiresRework, isFalse);
    });

    test('parses REWORK verdict with findings', () async {
      final provider = FakeModelProvider('anthropic');
      provider.enqueue(textResponse(
        'Found issues:\n- Missing null check on sensor input\n- No regression test added\nVERDICT: REWORK',
      ));
      final reviewer = ModelReviewer(reviewerId: 'claude-final', provider: provider, modelName: 'claude-sonnet-5');

      final verdict = await reviewer.review(samplePackage());
      expect(verdict.outcome, ReviewOutcome.rework);
      expect(verdict.requiresRework, isTrue);
      expect(verdict.findings, hasLength(2));
    });

    test('an unparsable response fails closed to REWORK, never a silent pass', () async {
      final provider = FakeModelProvider('anthropic');
      provider.enqueue(textResponse('The change seems fine overall.'));
      final reviewer = ModelReviewer(reviewerId: 'r', provider: provider, modelName: 'm');

      final verdict = await reviewer.review(samplePackage());
      expect(verdict.outcome, ReviewOutcome.rework);
    });

    test('refuses to let a model review a patch it authored itself', () async {
      final provider = FakeModelProvider('nvidia-nim');
      final reviewer = ModelReviewer(reviewerId: 'self', provider: provider, modelName: 'coder-model');
      final authorId = ModelId(providerId: 'nvidia-nim', modelName: 'coder-model');

      expect(
        () => reviewer.review(samplePackage(), authorModelId: authorId),
        throwsA(isA<SameModelReviewException>()),
      );
    });

    test('accepts review from a genuinely different model', () async {
      final provider = FakeModelProvider('anthropic');
      provider.enqueue(textResponse('VERDICT: PASS'));
      final reviewer = ModelReviewer(reviewerId: 'claude', provider: provider, modelName: 'claude-sonnet-5');
      final authorId = ModelId(providerId: 'nvidia-nim', modelName: 'coder-model');

      final verdict = await reviewer.review(samplePackage(), authorModelId: authorId);
      expect(verdict.outcome, ReviewOutcome.pass);
    });
  });

  group('ReviewCycleRunner', () {
    test('stops rework loop at maxCycles even if reviewer keeps requesting rework', () async {
      final provider = FakeModelProvider('anthropic');
      provider
        ..enqueue(textResponse('VERDICT: REWORK\n- issue 1'))
        ..enqueue(textResponse('VERDICT: REWORK\n- issue 1 still present'))
        ..enqueue(textResponse('VERDICT: REWORK\n- issue 1 still present'));
      final reviewer = ModelReviewer(reviewerId: 'claude', provider: provider, modelName: 'claude-sonnet-5');
      final runner = ReviewCycleRunner(maxCycles: 3);
      var reworkCalls = 0;

      final (verdict, cycles) = await runner.run(
        reviewer: reviewer,
        initialPackage: samplePackage(),
        authorModelId: ModelId(providerId: 'nvidia-nim', modelName: 'coder-model'),
        performRework: (priorVerdict) async {
          reworkCalls++;
          return samplePackage();
        },
      );

      expect(cycles, 3);
      expect(reworkCalls, 2); // rework happens between cycles, not after the last one
      expect(verdict.outcome, ReviewOutcome.rework);
    });

    test('stops as soon as the reviewer passes', () async {
      final provider = FakeModelProvider('anthropic');
      provider
        ..enqueue(textResponse('VERDICT: REWORK\n- issue 1'))
        ..enqueue(textResponse('VERDICT: PASS'));
      final reviewer = ModelReviewer(reviewerId: 'claude', provider: provider, modelName: 'claude-sonnet-5');
      final runner = ReviewCycleRunner(maxCycles: 5);

      final (verdict, cycles) = await runner.run(
        reviewer: reviewer,
        initialPackage: samplePackage(),
        authorModelId: ModelId(providerId: 'nvidia-nim', modelName: 'coder-model'),
        performRework: (priorVerdict) async => samplePackage(),
      );

      expect(cycles, 2);
      expect(verdict.outcome, ReviewOutcome.pass);
    });
  });
}
