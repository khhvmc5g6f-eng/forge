/// The task categories the Model Router selects among. Deliberately mirrors
/// the classification branches in the master brief's routing diagram.
enum TaskCategory {
  simpleCode,
  complexCode,
  architecture,
  debugging,
  vision,
  terminalOperation,
  repositoryResearch,
  testing,
  review,
}

/// Minimum requirements a [TaskCategory] implies, used by [ModelRouter] to
/// filter candidate models before ranking them.
class TaskRequirements {
  const TaskRequirements({
    this.requiresToolCalling = true,
    this.requiresVision = false,
    this.requiresReasoning = false,
    this.minContextWindowTokens = 8192,
    this.preferHighReliability = false,
  });

  final bool requiresToolCalling;
  final bool requiresVision;
  final bool requiresReasoning;
  final int minContextWindowTokens;

  /// Review and architecture tasks weight historical reliability more
  /// heavily than raw availability/cost; simple/local-friendly tasks don't.
  final bool preferHighReliability;

  static const Map<TaskCategory, TaskRequirements> byCategory = {
    TaskCategory.simpleCode: TaskRequirements(minContextWindowTokens: 8192),
    TaskCategory.complexCode: TaskRequirements(
      minContextWindowTokens: 32768,
      preferHighReliability: true,
    ),
    TaskCategory.architecture: TaskRequirements(
      requiresReasoning: true,
      minContextWindowTokens: 64000,
      preferHighReliability: true,
    ),
    TaskCategory.debugging: TaskRequirements(
      minContextWindowTokens: 32768,
      preferHighReliability: true,
    ),
    TaskCategory.vision: TaskRequirements(requiresVision: true),
    TaskCategory.terminalOperation: TaskRequirements(minContextWindowTokens: 8192),
    TaskCategory.repositoryResearch: TaskRequirements(minContextWindowTokens: 32768),
    TaskCategory.testing: TaskRequirements(minContextWindowTokens: 16384),
    TaskCategory.review: TaskRequirements(
      requiresReasoning: true,
      minContextWindowTokens: 64000,
      preferHighReliability: true,
    ),
  };
}

/// Cheap, deterministic first-pass classifier. This is intentionally not an
/// LLM call: classification must be fast, free, and available even when no
/// model is reachable. A future `LlmTaskClassifier` may refine ambiguous
/// cases, but the keyword/shape heuristics below cover the routing table in
/// the brief without spending a model call on every request.
class HeuristicTaskClassifier {
  TaskCategory classify(String taskDescription, {bool hasImageAttachment = false}) {
    if (hasImageAttachment) return TaskCategory.vision;
    final text = taskDescription.toLowerCase();

    bool any(List<String> words) => words.any(text.contains);

    if (any(['review', 'audit', 'critique', 'approve', 'sign off'])) {
      return TaskCategory.review;
    }
    if (any(['test', 'pytest', 'flutter test', 'unit test', 'integration test'])) {
      return TaskCategory.testing;
    }
    if (any(['debug', 'crash', 'stack trace', 'exception', 'failing', 'bug', 'cpu', 'memory leak'])) {
      return TaskCategory.debugging;
    }
    if (any(['architecture', 'design the', 'redesign', 'migrate', 'refactor the whole', 'trade-off'])) {
      return TaskCategory.architecture;
    }
    if (any(['run ', 'terminal', 'shell', 'command line', 'install ', 'build the project'])) {
      return TaskCategory.terminalOperation;
    }
    if (any(['find where', 'search the repo', 'investigate why', 'understand how', 'locate '])) {
      return TaskCategory.repositoryResearch;
    }
    if (text.split(RegExp(r'\s+')).length > 40 || any(['implement a', 'build a full', 'multi-file'])) {
      return TaskCategory.complexCode;
    }
    return TaskCategory.simpleCode;
  }
}
