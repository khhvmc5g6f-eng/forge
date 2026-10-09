/// Neural Observatory — the core telemetry model.
///
/// Flutter-free pure Dart, per ARCHITECTURE.md's layering rule: the same
/// events are produced and consumed by the desktop shell, the CLI and the
/// test suite. Field naming follows the OpenTelemetry trace model
/// (trace/span/parent ids, span kind, status) closely enough that exporting
/// to an OTLP-compatible collector later is a serialisation change, not a
/// redesign.
library;

import 'package:uuid/uuid.dart';

/// How a reported number came to exist. The Observatory never presents a
/// fabricated value as a measurement: anything this environment cannot
/// actually observe is surfaced as [unavailable], never guessed.
enum MeasurementQuality {
  /// Read directly from a local instrument: a Stopwatch, the process
  /// table, or a byte counter on a socket we own.
  measured,

  /// Reported by the provider inside a response body (token usage is the
  /// canonical example) — trusted as reported, not independently verified.
  providerReported,

  /// Derived arithmetically from measured/reported inputs — tokens/sec,
  /// cost from configured pricing, percentile latencies.
  calculated,

  /// A model-based projection (context-window exhaustion ETA, trend
  /// lines). Always rendered with its uncertainty disclosed.
  estimated,

  /// Cannot be measured here. Never rendered as a number. A remotely
  /// hosted model's GPU utilisation is the standard example: unless the
  /// provider exposes genuine resource telemetry, this stays unavailable.
  unavailable,
}

/// The execution phases the execution graph and cost breakdown group by.
enum SpanKind { session, agent, model, tool, network, resource, other }

/// The terminal status of a span.
enum SpanStatus { ok, error, running }

/// One correlated unit of work. Spans form a tree within a session via
/// `parentSpanId` (agent → model request → tool call), and every span
/// carries the session id so a whole conversation's history can be
/// reconstructed for replay without shipping raw conversation content.
class ObsSpan {
  ObsSpan({
    required this.spanId,
    required this.traceId,
    required this.kind,
    required this.name,
    required this.sessionId,
    required this.startedAt,
    this.parentSpanId,
    this.taskId,
    this.agentId,
    this.agentRole,
    this.endedAt,
    this.status = SpanStatus.running,
    Map<String, dynamic>? attributes,
  }) : attributes = attributes ?? <String, dynamic>{};

  final String spanId;
  final String traceId;
  final String? parentSpanId;
  final SpanKind kind;
  final String name;
  final String sessionId;
  final String? taskId;
  final String? agentId;
  final String? agentRole;

  final DateTime startedAt;
  DateTime? endedAt;

  SpanStatus status;

  /// Structured attributes. Values are plain JSON-encodable types; any key
  /// that looks like a credential is redacted by [redactAttributes] before
  /// persistence. Measured numeric attributes carry a `'<key>.quality'`
  /// companion naming their [MeasurementQuality].
  final Map<String, dynamic> attributes;

  /// Elapsed span time; null while still running.
  Duration? get duration => endedAt?.difference(startedAt);

  /// Marks the span finished. Idempotent: the first call wins, so a span
  /// can be fail-closed from multiple catch paths safely.
  void end({SpanStatus? withStatus}) {
    if (endedAt != null) return;
    endedAt = DateTime.now();
    if (withStatus != null) status = withStatus;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'traceId': traceId,
        'spanId': spanId,
        'parentSpanId': parentSpanId,
        'kind': kind.name,
        'name': name,
        'sessionId': sessionId,
        'taskId': taskId,
        'agentId': agentId,
        'agentRole': agentRole,
        'startTime': startedAt.toIso8601String(),
        'endTime': endedAt?.toIso8601String(),
        'durationMs': duration?.inMilliseconds,
        'status': status.name,
        'attributes': attributes,
      };
}

/// Attribute-key fragments that must never be persisted or displayed
/// verbatim. ('token' matches token *counts* too, so counts are exempted
/// explicitly below.)
const Set<String> _sensitiveKeyFragments = {
  'authorization',
  'credential',
  'key',
  'password',
  'secret',
  'token',
};

/// Redacts values of attribute keys that look like they carry secrets, and
/// truncates long opaque strings in free-text attribute values. Telemetry
/// is written to disk, so this runs before every [ObsSpan] reaches a store.
Map<String, dynamic> redactAttributes(Map<String, dynamic> attributes) {
  final redacted = <String, dynamic>{};
  attributes.forEach((key, value) {
    final lower = key.toLowerCase();
    final looksSensitive = _sensitiveKeyFragments.any(lower.contains);
    // Metadata labels (e.g. `tokensPerSecond.quality`) carry the
    // MeasurementQuality of a sibling metric — they describe a number,
    // they never hold a secret.
    final isQualityLabel = lower.endsWith('.quality');
    // Secrets are strings/maps; token *counts* (promptTokens, tokensIn…)
    // are numbers and must survive for analytics. Type, not key naming,
    // decides: a string or container under a sensitive-looking key is
    // redacted, a number is kept.
    final isSecretShaped = looksSensitive &&
        !isQualityLabel &&
        value is! num &&
        value is! bool;
    if (isSecretShaped) {
      redacted[key] = '[redacted]';
    } else if (value is String && value.length > 64) {
      redacted[key] = '${value.substring(0, 24)}…[truncated]';
    } else {
      redacted[key] = value;
    }
  });
  return redacted;
}

const Uuid _uuid = Uuid();

/// Fresh correlation identifiers, OpenTelemetry-style.
String newTraceId() => _uuid.v4();
String newSpanId() => _uuid.v4().substring(0, 16);

/// The instrumentation seam the agent runtime and orchestrator call. Kept
/// as an abstract class (not a dependency on [ObservatoryService]) so
/// `lib/core/agents/` depends on this narrow interface only, and so tests
/// can supply fakes.
///
/// Correlation (session/task ids) is stamped by the adapter the app layer
/// obtains from `ObservatoryService.telemetryFor`, not by the runtime —
/// the runtime has no legitimate way to know either id.
abstract class AgentTelemetry {
  void agentStarted({
    required String agentId,
    required String role,
    String? parentAgentId,
  });

  void agentFinished({
    required String agentId,
    required String role,
    required String status,
    required int iterations,
    required int promptTokens,
    required int completionTokens,
    required int cachedPromptTokens,
  });

  void modelRequest({
    required String agentId,
    required String role,
    required String providerId,
    required String modelName,
    required int latencyMs,
    int? ttftMs,
    required bool succeeded,
    bool rateLimited = false,
    required int promptTokens,
    required int completionTokens,
    required int cachedPromptTokens,
  });

  void toolCall({
    required String agentId,
    required String role,
    required String toolName,
    required int durationMs,
    required bool succeeded,
    required String decision,
  });
}

