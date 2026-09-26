import 'package:meta/meta.dart';

/// Static/declared capabilities of a model, as reported by a provider's
/// model-listing endpoint or configured manually for providers that don't
/// expose one.
@immutable
class ModelCapabilities {
  const ModelCapabilities({
    this.supportsToolCalling = false,
    this.supportsVision = false,
    this.supportsReasoningEffort = false,
    this.supportsStreaming = true,
    this.contextWindowTokens = 8192,
    this.maxOutputTokens = 4096,
    this.isFree = false,
    this.isLocal = false,
  });

  final bool supportsToolCalling;
  final bool supportsVision;
  final bool supportsReasoningEffort;
  final bool supportsStreaming;
  final int contextWindowTokens;
  final int maxOutputTokens;
  final bool isFree;
  final bool isLocal;

  ModelCapabilities copyWith({
    bool? supportsToolCalling,
    bool? supportsVision,
    bool? supportsReasoningEffort,
    bool? supportsStreaming,
    int? contextWindowTokens,
    int? maxOutputTokens,
    bool? isFree,
    bool? isLocal,
  }) {
    return ModelCapabilities(
      supportsToolCalling: supportsToolCalling ?? this.supportsToolCalling,
      supportsVision: supportsVision ?? this.supportsVision,
      supportsReasoningEffort:
          supportsReasoningEffort ?? this.supportsReasoningEffort,
      supportsStreaming: supportsStreaming ?? this.supportsStreaming,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      isFree: isFree ?? this.isFree,
      isLocal: isLocal ?? this.isLocal,
    );
  }
}

/// Empirically observed performance for a (provider, model) pair, updated by
/// the Model Arena and by live usage. This is the data the Model Router
/// actually ranks on — [ModelCapabilities] only says what *should* be
/// possible, this says what has *actually worked*.
@immutable
class ModelPerformanceRecord {
  const ModelPerformanceRecord({
    this.codingReliability = 0.5,
    this.toolReliability = 0.5,
    this.reasoningReliability = 0.5,
    this.averageLatencyMs = 0,
    this.successCount = 0,
    this.failureCount = 0,
    this.rateLimitedCount = 0,
    this.lastTested,
  });

  final double codingReliability;
  final double toolReliability;
  final double reasoningReliability;
  final int averageLatencyMs;
  final int successCount;
  final int failureCount;
  final int rateLimitedCount;
  final DateTime? lastTested;

  int get totalRuns => successCount + failureCount;

  double get successRate => totalRuns == 0 ? 0.5 : successCount / totalRuns;

  ModelPerformanceRecord withResult({
    required bool succeeded,
    required int latencyMs,
    bool rateLimited = false,
  }) {
    final newSuccess = successCount + (succeeded ? 1 : 0);
    final newFailure = failureCount + (succeeded ? 0 : 1);
    final newTotal = newSuccess + newFailure;
    final blendedLatency = newTotal == 0
        ? 0
        : (((averageLatencyMs * totalRuns) + latencyMs) / newTotal).round();
    return ModelPerformanceRecord(
      codingReliability: codingReliability,
      toolReliability: toolReliability,
      reasoningReliability: reasoningReliability,
      averageLatencyMs: blendedLatency,
      successCount: newSuccess,
      failureCount: newFailure,
      rateLimitedCount: rateLimitedCount + (rateLimited ? 1 : 0),
      lastTested: DateTime.now(),
    );
  }

  ModelPerformanceRecord withArenaScores({
    double? codingReliability,
    double? toolReliability,
    double? reasoningReliability,
  }) {
    return ModelPerformanceRecord(
      codingReliability: codingReliability ?? this.codingReliability,
      toolReliability: toolReliability ?? this.toolReliability,
      reasoningReliability: reasoningReliability ?? this.reasoningReliability,
      averageLatencyMs: averageLatencyMs,
      successCount: successCount,
      failureCount: failureCount,
      rateLimitedCount: rateLimitedCount,
      lastTested: DateTime.now(),
    );
  }
}
