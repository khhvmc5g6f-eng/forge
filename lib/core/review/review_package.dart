/// The compact bundle handed to a [Reviewer] instead of the full development
/// transcript, per the brief: "Claude should receive a compact Review
/// Package rather than the entire development conversation." Built by the
/// Final Review Preparation Agent from the completed [Task]'s Git diff,
/// build/test output, and a short implementation summary.
class ReviewPackage {
  const ReviewPackage({
    required this.taskTitle,
    required this.originalProblem,
    required this.requirements,
    required this.implementationSummary,
    required this.architecturalChanges,
    required this.diff,
    required this.filesChanged,
    required this.testsRun,
    required this.buildResultSummary,
    this.beforeAfterNotes = '',
    this.knownLimitations = const [],
    this.securityReviewNotes = '',
    this.performanceResults = '',
  });

  final String taskTitle;
  final String originalProblem;
  final String requirements;
  final String implementationSummary;
  final String architecturalChanges;
  final String diff;
  final List<String> filesChanged;
  final List<String> testsRun;
  final String buildResultSummary;
  final String beforeAfterNotes;
  final List<String> knownLimitations;
  final String securityReviewNotes;
  final String performanceResults;

  /// Renders the package as the single prompt handed to a [Reviewer]. Kept
  /// as plain, labelled text rather than JSON: the reviewer is an LLM, and a
  /// clearly labelled prompt is both cheaper (fewer structural tokens) and
  /// easier for the model to follow than an equivalent JSON blob.
  String render() {
    final buffer = StringBuffer()
      ..writeln('# Review Package: $taskTitle')
      ..writeln()
      ..writeln('## Original problem')
      ..writeln(originalProblem)
      ..writeln()
      ..writeln('## Requirements')
      ..writeln(requirements)
      ..writeln()
      ..writeln('## Implementation summary')
      ..writeln(implementationSummary)
      ..writeln()
      ..writeln('## Architectural changes')
      ..writeln(architecturalChanges.isEmpty ? '(none)' : architecturalChanges)
      ..writeln()
      ..writeln('## Files changed (${filesChanged.length})')
      ..writeln(filesChanged.join('\n'))
      ..writeln()
      ..writeln('## Diff')
      ..writeln('```diff')
      ..writeln(diff)
      ..writeln('```')
      ..writeln()
      ..writeln('## Tests run')
      ..writeln(testsRun.isEmpty ? '(none)' : testsRun.join('\n'))
      ..writeln()
      ..writeln('## Build result')
      ..writeln(buildResultSummary)
      ..writeln()
      ..writeln('## Before / after')
      ..writeln(beforeAfterNotes.isEmpty ? '(not captured)' : beforeAfterNotes)
      ..writeln()
      ..writeln('## Known limitations')
      ..writeln(knownLimitations.isEmpty ? '(none declared)' : knownLimitations.join('\n'))
      ..writeln()
      ..writeln('## Security review notes')
      ..writeln(securityReviewNotes.isEmpty ? '(not assessed)' : securityReviewNotes)
      ..writeln()
      ..writeln('## Performance results')
      ..writeln(performanceResults.isEmpty ? '(not measured)' : performanceResults)
      ..writeln()
      ..writeln(
          'Independently identify: logic errors, architectural mistakes, '
          'regressions, security concerns, missing tests, edge cases, '
          'unnecessary complexity, incorrect assumptions. Conclude with '
          'exactly one of: APPROVE or REWORK REQUIRED, each with the '
          'specific evidence backing it.');
    return buffer.toString();
  }
}
