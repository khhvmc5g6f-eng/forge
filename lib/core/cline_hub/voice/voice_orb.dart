import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'voice_messages.dart';

/// Live voice visual. While the user is speaking it draws the REAL recent input
/// levels (a rolling buffer of microphone amplitude samples). For processing and
/// speaking it shows state-based motion, because there is no audio level to read
/// (recognition happens on the Mac; speech is played by the OS voice).
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.state,
    required this.level,
    this.size = 200,
  });
  final VoiceUiState state;
  final double level;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );
  static const _bars = 48;
  final List<double> _history = List<double>.filled(_bars, 0, growable: true);

  bool get _animated => switch (widget.state) {
    VoiceUiState.transcribing ||
    VoiceUiState.understanding ||
    VoiceUiState.executing ||
    VoiceUiState.speaking ||
    VoiceUiState.speechDetected => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(VoiceOrb old) {
    super.didUpdateWidget(old);
    _history
      ..removeAt(0)
      ..add(widget.level);
    _sync();
  }

  // The ticker only runs while something is happening, so an idle orb costs nothing.
  void _sync() {
    if (_animated && !_c.isAnimating) {
      _c.repeat();
    } else if (!_animated && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color _color(ColorScheme s) => switch (widget.state) {
    VoiceUiState.off => s.outline,
    VoiceUiState.listening => s.primary,
    VoiceUiState.speechDetected => s.tertiary,
    VoiceUiState.transcribing || VoiceUiState.understanding => s.secondary,
    VoiceUiState.executing => s.primary,
    VoiceUiState.speaking => s.tertiary,
    VoiceUiState.paused => s.outline,
    VoiceUiState.error => s.error,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Voice status: ${widget.state.label}',
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _OrbPainter(
              color: _color(scheme),
              state: widget.state,
              level: widget.level,
              history: List.of(_history),
              t: _c.value,
              bg: scheme.surfaceContainerHighest,
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.color,
    required this.state,
    required this.level,
    required this.history,
    required this.t,
    required this.bg,
  });
  final Color color;
  final VoiceUiState state;
  final double level;
  final List<double> history;
  final double t;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final base = r * 0.45;
    final pulse = switch (state) {
      VoiceUiState.speaking =>
        0.06 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 3)),
      VoiceUiState.executing => 0.04 * (0.5 + 0.5 * math.sin(t * 2 * math.pi)),
      _ => 0.0,
    };
    final core = base * (1 + level * 0.35 + pulse);
    canvas.drawCircle(c, r * 0.92, Paint()..color = bg);
    canvas.drawCircle(
      c,
      core * 1.25,
      Paint()..color = color.withValues(alpha: 0.18),
    );
    canvas.drawCircle(
      c,
      core,
      Paint()
        ..color = color.withValues(
          alpha: state == VoiceUiState.off ? 0.35 : 0.9,
        ),
    );

    // Ring of bars = the real recent input levels while the mic is capturing.
    if (state == VoiceUiState.speechDetected ||
        state == VoiceUiState.listening) {
      final n = history.length;
      final p = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < n; i++) {
        final a = -math.pi / 2 + i * 2 * math.pi / n;
        final len = 4 + history[i] * r * 0.32;
        final r0 = base * 1.5;
        canvas.drawLine(
          c + Offset(math.cos(a), math.sin(a)) * r0,
          c + Offset(math.cos(a), math.sin(a)) * (r0 + len),
          p,
        );
      }
    }
    // Processing: a rotating arc.
    if (state == VoiceUiState.transcribing ||
        state == VoiceUiState.understanding) {
      final rect = Rect.fromCircle(center: c, radius: base * 1.55);
      canvas.drawArc(
        rect,
        t * 2 * math.pi,
        math.pi * 1.1,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter o) =>
      o.t != t || o.state != state || o.level != level || o.color != color;
}
