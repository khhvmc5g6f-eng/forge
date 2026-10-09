import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/neural/mlp_engine.dart';

/// The analytics dock for the Neural Lab: live metrics, loss curves (with a
/// log-scale toggle), decision-boundary map, gradient bars and the confusion
/// matrix. Extracted from `neural_lab_panel.dart` (previously a single
/// 936-line file) so the panel library holds only the experiment controller
/// and stage, while this library holds the purely presentational charts.
/// Everything here is fed through constructors — no coupling back to the
/// panel's state, and no behaviour changed by the extraction.

class NeuralLabAnalyticsDock extends StatelessWidget {
  const NeuralLabAnalyticsDock({
    super.key,
    required this.history,
    required this.gradNorms,
    required this.confusion,
    required this.test,
    required this.net,
    required this.trainLoss,
    required this.testLoss,
    required this.acc,
    required this.phase,
    required this.epoch,
    required this.lossLog,
    required this.onToggleLog,
  });

  final List<({int step, double trainLoss, double testLoss, double acc})> history;
  final List<double> gradNorms;
  final List<int> confusion;
  final List<NnPoint> test;
  final MLP net;
  final double trainLoss, testLoss, acc;
  final String phase;
  final int epoch;
  final bool lossLog;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border(left: BorderSide(color: scheme.outlineVariant, width: 0.5)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(10),
        children: [
          Row(children: [
            Expanded(
                child: _metric(context, 'Train loss', trainLoss.toStringAsFixed(4), scheme.onSurface)),
            Expanded(
                child: _metric(context, 'Test loss', testLoss.toStringAsFixed(4), scheme.onSurface)),
            Expanded(
              child: _metric(
                  context,
                  'Accuracy',
                  '${(acc * 100).toStringAsFixed(1)}% · $phase',
                  acc > 0.9
                      ? const Color(0xFF34D399)
                      : acc > 0.7
                          ? const Color(0xFFFFD166)
                          : const Color(0xFFF87171)),
            ),
          ]),
          Text('epoch $epoch',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          _card(
            context,
            'Loss curves',
            IconButton(
              icon: Icon(lossLog ? Icons.functions : Icons.linear_scale, size: 16),
              tooltip: 'Toggle log scale',
              onPressed: onToggleLog,
            ),
            _LossChart(history: history, logScale: lossLog),
            130,
          ),
          _card(context, 'Decision boundary', null, _BoundaryChart(net: net, test: test), 200),
          _card(context, 'Gradient flow', null, _GradChart(norms: gradNorms), 110),
          _card(context, 'Confusion matrix', null, _ConfusionChart(confusion: confusion), 130),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value, Color color) => Column(
        children: [
          Text(label.toUpperCase(),
              style:
                  TextStyle(fontSize: 9, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          Text(value,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: color)),
        ],
      );

  Widget _card(BuildContext context, String title, Widget? action, Widget chart, double height) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 0.5),
        ),
        padding: const EdgeInsets.all(8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title.toUpperCase(),
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurfaceVariant))),
            ?action,
          ]),
          const SizedBox(height: 6),
          Semantics(
            label: '$title chart',
            child: SizedBox(height: height, width: double.infinity, child: chart),
          ),
        ]),
      ),
    );
  }
}

typedef _HistEntry = ({int step, double trainLoss, double testLoss, double acc});

double _log10(double x) => math.log(x) / math.ln10;


class _LossChart extends StatelessWidget {
  const _LossChart({required this.history, required this.logScale});
  final List<_HistEntry> history;
  final bool logScale;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _LossChartPainter(history, logScale), size: Size.infinite);
}

class _LossChartPainter extends CustomPainter {
  _LossChartPainter(this.history, this.logScale);
  final List<_HistEntry> history;
  final bool logScale;

  double _val(double v) => logScale ? _log10(v.clamp(1e-4, 10.0)) : v;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
        Paint()..color = const Color(0x11000000));
    if (history.length < 2) return;
    var maxL = 0.05;
    for (final d in history) {
      maxL = math.max(maxL, math.max(d.trainLoss, d.testLoss));
    }
    final vMin = logScale ? _log10(1e-4) : 0.0;
    final vMax = logScale ? _log10(math.max(maxL, 1e-4)) : maxL;
    Offset pt(int i, double v) => Offset(
        4 + i / (history.length - 1) * (size.width - 38),
        size.height - 6 - (_val(v) - vMin) / (vMax - vMin) * (size.height - 14));
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final ticks = logScale
        ? <({String label, double v})>[
            for (var e = -4; e <= 0; e++)
              (label: '1e$e', v: math.pow(10.0, e).toDouble()),
          ]
        : <({String label, double v})>[
            (label: '0', v: 0),
            (label: (maxL / 2).toStringAsFixed(2), v: maxL / 2),
            (label: maxL.toStringAsFixed(2), v: maxL),
          ];
    for (final t in ticks) {
      final y = size.height - 6 - (_val(t.v) - vMin) / (vMax - vMin) * (size.height - 14);
      canvas.drawLine(Offset(4, y), Offset(size.width - 38, y),
          Paint()..color = const Color(0x22FFFFFF)..strokeWidth = 0.5);
      tp.text = TextSpan(
          text: t.label, style: const TextStyle(fontSize: 8, color: Color(0xFF8B95AB)));
      tp.layout();
      tp.paint(canvas, Offset(size.width - 34, y - 4));
    }
    void line(double Function(_HistEntry) pick, Color c) {
      final p = Paint()
        ..color = c
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < history.length; i++) {
        final o = pt(i, pick(history[i]));
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, p);
    }
    line((d) => d.trainLoss, const Color(0xFF3FD6FF));
    line((d) => d.testLoss, const Color(0xFFFF7A3C));
  }

  @override
  bool shouldRepaint(_LossChartPainter old) => true;
}

class _BoundaryChart extends StatelessWidget {
  const _BoundaryChart({required this.net, required this.test});
  final MLP net;
  final List<NnPoint> test;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _BoundaryPainter(net, test), size: Size.infinite);
}

class _BoundaryPainter extends CustomPainter {
  _BoundaryPainter(this.net, this.test);
  final MLP net;
  final List<NnPoint> test;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 42.0;
    final cell = Size(size.width / n, size.height / n);
    final grid = Paint();
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final x = (c / (n - 1)) * 2 - 1;
        final y = 1 - (r / (n - 1)) * 2;
        final p = net.predict(x, y);
        grid.color = p >= 0.5
            ? Color.fromRGBO(63, 214, 255, 0.08 + 0.30 * (p - 0.5) * 2)
            : Color.fromRGBO(255, 122, 60, 0.08 + 0.30 * (0.5 - p) * 2);
        canvas.drawRect(Offset(c * cell.width, r * cell.height) & cell, grid);
      }
    }
    final dot = Paint();
    for (final p in test) {
      dot.color = p.label == 1 ? Colors.white : const Color(0xFF131722);
      canvas.drawCircle(
          Offset((p.x + 1) / 2 * size.width, (1 - (p.y + 1) / 2) * size.height),
          2.2,
          dot);
    }
  }

  @override
  bool shouldRepaint(_BoundaryPainter old) => true;
}

class _GradChart extends StatelessWidget {
  const _GradChart({required this.norms});
  final List<double> norms;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _GradPainter(norms), size: Size.infinite);
}

class _GradPainter extends CustomPainter {
  _GradPainter(this.norms);
  final List<double> norms;

  @override
  void paint(Canvas canvas, Size size) {
    if (norms.isEmpty) return;
    final max = norms.reduce(math.max).clamp(1e-9, 1e9);
    double tOf(double v) => _log10(1 + v * 1e4) / _log10(1 + max * 1e4);
    final bh = (size.height - 6) / norms.length;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var l = 0; l < norms.length; l++) {
      final bw = tOf(norms[l]) * (size.width - 100);
      canvas.drawRect(Rect.fromLTWH(56, 3.0 + l * bh, size.width - 60, bh - 6),
          Paint()..color = const Color(0x223FD6FF));
      canvas.drawRect(Rect.fromLTWH(56, 3.0 + l * bh, math.max(2, bw), bh - 6),
          Paint()..color = const Color(0xFF3FD6FF));
      tp.text = TextSpan(
          text: 'L$l ${norms[l].toStringAsExponential(1)}',
          style: const TextStyle(fontSize: 8, color: Color(0xFF8B95AB)));
      tp.layout();
      tp.paint(canvas, Offset(58 + math.max(2, bw) + 3, 3.0 + l * bh + bh / 2 - 5));
    }
  }

  @override
  bool shouldRepaint(_GradPainter old) => true;
}

class _ConfusionChart extends StatelessWidget {
  const _ConfusionChart({required this.confusion});
  final List<int> confusion;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _ConfusionPainter(confusion), size: Size.infinite);
}

class _ConfusionPainter extends CustomPainter {
  _ConfusionPainter(this.confusion);
  final List<int> confusion; // TP, FP, FN, TN

  @override
  void paint(Canvas canvas, Size size) {
    final (tp, fp, fn, tn) = (confusion[0], confusion[1], confusion[2], confusion[3]);
    final total = math.max(1, tp + fp + fn + tn);
    final x0 = 58.0;
    final cw = (size.width - x0 - 22) / 2;
    final chh = (size.height - 58) / 2;
    final cells = [
      (v: tn, label: 'TN', x: x0, y: 4.0, c: const Color(0xFF34D399)),
      (v: fp, label: 'FP', x: x0 + cw + 4, y: 4.0, c: const Color(0xFFF87171)),
      (v: fn, label: 'FN', x: x0, y: 4.0 + chh + 4, c: const Color(0xFFF87171)),
      (v: tp, label: 'TP', x: x0 + cw + 4, y: 4.0 + chh + 4, c: const Color(0xFF34D399)),
    ];
    final tp2 = TextPainter(textDirection: TextDirection.ltr);
    for (final c in cells) {
      final a = c.v / total;
      canvas.drawRect(Rect.fromLTWH(c.x, c.y, cw, chh),
          Paint()..color = c.c.withValues(alpha: 0.15 + 0.7 * a));
      tp2.text = TextSpan(
          text: '${c.label} ${c.v}',
          style: const TextStyle(fontSize: 9, color: Color(0xFFE8ECF4)));
      tp2.layout();
      tp2.paint(canvas, Offset(c.x + 5, c.y + 4));
    }
    tp2.text = const TextSpan(
        text: 'pred 0        pred 1',
        style: TextStyle(fontSize: 8, color: Color(0xFF8B95AB)));
    tp2.layout();
    tp2.paint(canvas, Offset(x0, size.height - 34));
    tp2.text = const TextSpan(
        text: 'actual 0\nactual 1',
        style: TextStyle(fontSize: 8, color: Color(0xFF8B95AB)));
    tp2.layout();
    tp2.paint(canvas, const Offset(2, 8));
    final prec = tp + fp > 0 ? (tp / (tp + fp)).toStringAsFixed(2) : '-';
    final rec = tp + fn > 0 ? (tp / (tp + fn)).toStringAsFixed(2) : '-';
    tp2.text = TextSpan(
        text: 'precision $prec - recall $rec',
        style: const TextStyle(fontSize: 9, color: Color(0xFF8B95AB)));
    tp2.layout();
    tp2.paint(canvas, Offset(x0, size.height - 12));
  }

  @override
  bool shouldRepaint(_ConfusionPainter old) => true;
}



