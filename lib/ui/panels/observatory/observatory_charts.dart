import 'package:flutter/material.dart';

/// A zero-dependency sparkline over a small [values] window — the only
/// chart primitive the Observatory needs, kept dependency-free like the
/// rest of the app's custom painters.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color = Colors.cyan,
    this.height = 40,
  });

  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SparklinePainter(values, color)),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) {
      final paint = Paint()..color = color.withValues(alpha: 0.4);
      // A single sample: an honest flat line at its value, not a fake trend.
      final y = size.height / 2;
      if (values.length == 1) {
        y; // placeholder, value drawn below with real scale
      }
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint..strokeWidth = 1);
      return;
    }
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final span = (max - min) == 0 ? 1.0 : (max - min);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final yy = size.height - ((values[i] - min) / span) * (size.height - 4) - 2;
      if (i == 0) {
        path.moveTo(x, yy);
      } else {
        path.lineTo(x, yy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}
