import '../models/chat_types.dart';
import '../models/model_provider.dart';
import 'review_package.dart';

enum ReviewOutcome { pass, passWithConcerns, rework, fail }

class ReviewVerdict {
  const ReviewVerdict({required this.outcome, required this.findings, required this.rawResponse});
  final ReviewOutcome outcome;
  final List<String> findings;
  final String rawResponse;

  bool get requiresRework => outcome == ReviewOutcome.rework || outcome == ReviewOutcome.fail;
}

/// Thrown when a caller tries to have a model review its own patch. Per
/// RESEARCH_FINDINGS.md: "the model that authored a substantial patch is
/// never its sole reviewer" — this is enforced in code, not left to prompt
/// discipline.
class SameModelReviewException implements Exception {
  SameModelReviewException(this.modelId);
  final ModelId modelId;
  @override
  String toString() =>
      'Refusing to let ${modelId.key} review a patch it authored. Use a different reviewer model.';
}

/// Pluggable Final/Independent Reviewer. Both the Independent Review Agent
/// (any different model from the author) and the optional Claude Final
/// Review sit behind this one interface, so Claude can be replaced or
/// supplemented later without touching the orchestration code that calls
/// reviewers, per the brief: "Make the reviewer provider abstract so Claude
/// can be replaced or supplemented later."
abstract class Reviewer {
  String get reviewerId;
  ModelId get modelId;

  Future<ReviewVerdict> review(ReviewPackage package);
}

const _reviewerSystemPrompt =
    'You are an independent reviewer. You did not author the change under '
    'review. Read the review package and identify logic errors, '
    'architectural mistakes, regressions, security concerns, missing tests, '
    'edge cases, unnecessary complexity, and incorrect assumptions. End your '
    'response with exactly one verdict line: "VERDICT: PASS", '
    '"VERDICT: PASS WITH CONCERNS", "VERDICT: REWORK", or "VERDICT: FAIL", '
    'followed by a bulleted list of concrete findings (empty if PASS).';

/// A model-backed reviewer usable both as the "different review model" in
/// the ordinary independent-review step, and — configured with an
/// [AnthropicProvider] — as the Claude Final Review step. Behaviour is
/// identical; only which [ModelProvider]/model is passed in differs.
class ModelReviewer implements Reviewer {
  ModelReviewer({
    required this._reviewerId,
    required this.provider,
    required this.modelName,
  });

  final String _reviewerId;
  final ModelProvider provider;
  final String modelName;

  @override
  String get reviewerId => _reviewerId;

  @override
  ModelId get modelId => ModelId(providerId: provider.providerId, modelName: modelName);

  /// Reviews [package], refusing if [authorModelId] matches this reviewer's
  /// own model — see [SameModelReviewException].
  @override
  Future<ReviewVerdict> review(ReviewPackage package, {ModelId? authorModelId}) async {
    if (authorModelId != null && authorModelId == modelId) {
      throw SameModelReviewException(authorModelId);
    }
    final result = await provider.chat(
      modelName,
      ChatRequest(messages: [
        const ChatMessage.system(_reviewerSystemPrompt),
        ChatMessage.user(package.render()),
      ]),
    );
    return _parseVerdict(result.message.content);
  }

  ReviewVerdict _parseVerdict(String content) {
    final upper = content.toUpperCase();
    ReviewOutcome outcome;
    if (upper.contains('VERDICT: FAIL')) {
      outcome = ReviewOutcome.fail;
    } else if (upper.contains('VERDICT: REWORK')) {
      outcome = ReviewOutcome.rework;
    } else if (upper.contains('VERDICT: PASS WITH CONCERNS')) {
      outcome = ReviewOutcome.passWithConcerns;
    } else if (upper.contains('VERDICT: PASS')) {
      outcome = ReviewOutcome.pass;
    } else if (upper.contains('APPROVE')) {
      outcome = ReviewOutcome.pass;
    } else if (upper.contains('REWORK REQUIRED')) {
      outcome = ReviewOutcome.rework;
    } else {
      // Fail closed: an unparsable verdict is treated as requiring rework
      // rather than silently passing.
      outcome = ReviewOutcome.rework;
    }
    final findings = content
        .split('\n')
        .where((line) => line.trim().startsWith('-') || line.trim().startsWith('*'))
        .map((line) => line.trim())
        .toList();
    return ReviewVerdict(outcome: outcome, findings: findings, rawResponse: content);
  }
}

/// Runs the Worker <-> Reviewer rework loop from the brief:
/// `WORKER AGENT -> REPAIR -> TEST -> REVIEW PACKAGE -> CLAUDE -> REWORK ->
/// WORKER -> RETEST -> CLAUDE`, bounded by a configurable maximum cycle
/// count so a disagreement between worker and reviewer cannot loop forever.
class ReviewCycleRunner {
  ReviewCycleRunner({required this.maxCycles});

  final int maxCycles;

  /// [performRework] is called with the reviewer's findings and must return
  /// an updated [ReviewPackage] reflecting the fix + retest. Returns the
  /// final verdict and the number of cycles actually used.
  Future<(ReviewVerdict, int)> run({
    required Reviewer reviewer,
    required ReviewPackage initialPackage,
    required ModelId authorModelId,
    required Future<ReviewPackage> Function(ReviewVerdict priorVerdict) performRework,
  }) async {
    var package = initialPackage;
    var cycles = 0;
    while (true) {
      final verdict = await (reviewer as ModelReviewer)
          .review(package, authorModelId: authorModelId);
      cycles++;
      if (!verdict.requiresRework || cycles >= maxCycles) {
        return (verdict, cycles);
      }
      package = await performRework(verdict);
    }
  }
}
