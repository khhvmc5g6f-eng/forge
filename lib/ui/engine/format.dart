import 'package:flutter/material.dart';

import '../../core/forge_engine/engine_models.dart';

/// "—" is how the UI says "the engine did not report this".
const unknownText = '—';

String fmtInt(num? n) {
  if (n == null) return unknownText;
  final a = n.abs();
  if (a >= 1e9) return '${(n / 1e9).toStringAsFixed(1)}B';
  if (a >= 1e6) return '${(n / 1e6).toStringAsFixed(1)}M';
  if (a >= 1e4) return '${(n / 1e3).toStringAsFixed(1)}k';
  return n.round().toString();
}

String fmtMs(num? ms) {
  if (ms == null) return unknownText;
  if (ms >= 10000) return '${(ms / 1000).toStringAsFixed(0)} s';
  if (ms >= 1000) return '${(ms / 1000).toStringAsFixed(1)} s';
  return '${ms.round()} ms';
}

String fmtPct(double? fraction, {int digits = 0}) => fraction == null ? unknownText : '${(fraction * 100).toStringAsFixed(digits)}%';

String fmtScore(double? s) => s == null ? 'no data' : s.round().toString();

String _symbol(String c) => switch (c) {
      'USD' => r'$',
      'EUR' => '€',
      'GBP' => '£',
      _ => '$c ',
    };

/// Cost is shown only when the engine priced at least one call; otherwise it
/// says so instead of printing a misleading zero.
String fmtCost(EngineAggregate a) {
  if (!a.hasCost) return a.calls == 0 ? unknownText : 'unpriced';
  final v = a.cost;
  return '${_symbol(a.costCurrency!)}${v < 1 ? v.toStringAsFixed(4) : v.toStringAsFixed(2)}';
}

String fmtDuration(Duration d) {
  if (d.isNegative) return 'now';
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

String fmtAgo(DateTime? t, DateTime now) => t == null ? unknownText : '${fmtDuration(now.difference(t))} ago';

String fmtClock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// Colour for a circuit state. Greens only for states that carry traffic.
Color circuitColor(String state) => switch (state) {
      'closed' => const Color(0xFF2E9E5B),
      'degraded' => const Color(0xFFE0A100),
      'half_open' => const Color(0xFFE0A100),
      'open' || 'exhausted' => const Color(0xFFD64545),
      'cooldown' => const Color(0xFFD97A2B),
      'disabled' => const Color(0xFF7A7F87),
      _ => const Color(0xFF7A7F87),
    };

Color capacityColor(String status) => switch (status) {
      'healthy' => const Color(0xFF2E9E5B),
      'warning' => const Color(0xFFE0A100),
      'critical' => const Color(0xFFD97A2B),
      'exhausted' => const Color(0xFFD64545),
      _ => const Color(0xFF7A7F87),
    };

Color severityColor(String severity) => switch (severity) {
      'critical' => const Color(0xFFD64545),
      'warning' => const Color(0xFFE0A100),
      'success' => const Color(0xFF2E9E5B),
      _ => const Color(0xFF4A7BD0),
    };

IconData severityIcon(String severity) => switch (severity) {
      'critical' => Icons.error_outline,
      'warning' => Icons.warning_amber_outlined,
      'success' => Icons.check_circle_outline,
      _ => Icons.info_outline,
    };

String prettyState(String s) => s.replaceAll('_', ' ');
