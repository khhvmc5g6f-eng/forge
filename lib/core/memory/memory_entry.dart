/// The categories of durable project knowledge the brief calls out by name:
/// "architecture decisions, known issues, coding conventions, previous
/// failures, previous repairs, build commands, test procedures, device
/// quirks, user decisions."
enum MemoryKind {
  architectureDecision,
  knownIssue,
  priorFix,
  codingConvention,
  buildCommand,
  testProcedure,
  deviceQuirk,
  userDecision,
}

/// One durable piece of project knowledge, structured per the brief's
/// example:
/// ```
/// ISSUE: Cockpit high CPU
/// ROOT CAUSE: repeated listener registration
/// PATCH: ...
/// TEST: ...
/// RESULT: resolved
/// ```
/// `title`/`body` carry that free-text content; `tags` make it retrievable
/// by the Repository Agent for a later, similar problem.
class MemoryEntry {
  MemoryEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    List<String>? tags,
    this.taskId,
  }) : tags = tags ?? [];

  final String id;
  final MemoryKind kind;
  final String title;
  final String body;
  final DateTime createdAt;
  final List<String> tags;

  /// The Task this memory was recorded from, if any — lets a later task
  /// trace an applied fix back to its original diagnosis.
  final String? taskId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
        'tags': tags,
        'taskId': taskId,
      };

  factory MemoryEntry.fromJson(Map<String, dynamic> json) => MemoryEntry(
        id: json['id'] as String,
        kind: MemoryKind.values.byName(json['kind'] as String),
        title: json['title'] as String,
        body: json['body'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        tags: (json['tags'] as List).cast<String>(),
        taskId: json['taskId'] as String?,
      );
}
