/// Neural Observatory — generation-speed measurement for model output.
///
/// Two honest modes:
///  * streaming — real per-chunk timestamps produce a true tokens/sec
///    profile with time-to-first-token, peak rate and stall detection;
///  * non-streaming — the only observable quantities are the total
///    completion tokens and the request wall-clock, so the rate is
///    labelled a whole-request average, never an inter-token speed.
library;

import 'telemetry.dart';

/// Measures output token generation over time from real chunk arrivals.
class StreamRateAnalyzer {
  StreamRateAnalyzer({this.stallThreshold = const Duration(seconds: 2)});

  /// A gap between chunks longer than this counts as an output stall.
  final Duration stallThreshold;

  DateTime? _startedAt;
  DateTime? _firstTokenAt;
  DateTime? _lastTickAt;
  int _totalTokens = 0;
  double _peakPerSecond = 0;
  final List<Duration> _stalls = [];

  /// Wall-clock from construction/reset to the first token: TTFT.
  Duration? get timeToFirstToken =>
      _firstTokenAt == null || _startedAt == null
          ? null
          : _firstTokenAt!.difference(_startedAt!);

  int get totalTokens => _totalTokens;

  double get peakTokensPerSecond => _peakPerSecond;

  List<Duration> get stalls => List<Duration>.unmodifiable(_stalls);

  /// Call once at the start of a generation so TTFT has an origin.
  void start({DateTime? at}) {
    _startedAt = at ?? DateTime.now();
    _firstTokenAt = null;
    _lastTickAt = null;
    _totalTokens = 0;
    _peakPerSecond = 0;
    _stalls.clear();
  }

  /// Records the arrival of [tokens] (provider-reported token counts of the
  /// delta — a provider that reports none yields token-rate `unavailable`,
  /// never a character-count stand-in masquerading as tokens).
  void tick(int tokens, {DateTime? at}) {
    final now = at ?? DateTime.now();
    _startedAt ??= now;
    if (_lastTickAt != null) {
      final gap = now.difference(_lastTickAt!);
      if (gap > stallThreshold && tokens > 0) _stalls.add(gap);
      final seconds = gap.inMicroseconds / 1e6;
      if (tokens > 0 && seconds > 0) {
        final rate = tokens / seconds;
        if (rate > _peakPerSecond) _peakPerSecond = rate;
      }
    }
    if (tokens > 0) {
      _firstTokenAt ??= now;
      _totalTokens += tokens;
    }
    _lastTickAt = now;
  }

  /// Mean generation speed across the whole generation so far.
  /// `null` until there is a first token and an elapsed interval.
  double? get averageTokensPerSecond {
    if (_firstTokenAt == null || _lastTickAt == null) return null;
    final seconds = _lastTickAt!.difference(_firstTokenAt!).inMicroseconds / 1e6;
    return seconds <= 0 ? null : _totalTokens / seconds;
  }
}

/// The non-streaming case: one request, one response. The rate is the
/// whole-request average — labelled [MeasurementQuality.calculated] and
/// presented as such, since it includes queueing and network time.
class ChatRequestRate {
  const ChatRequestRate._(this.tokensPerSecond, this.latencyMs);

  factory ChatRequestRate.calculate({
    required int completionTokens,
    required int latencyMs,
  }) {
    if (completionTokens <= 0 || latencyMs <= 0) {
      return ChatRequestRate._(null, latencyMs);
    }
    return ChatRequestRate._(completionTokens / (latencyMs / 1000), latencyMs);
  }

  /// Whole-request average output tokens/sec, `null` when not computable.
  final double? tokensPerSecond;
  final int latencyMs;
}
