import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/neural/mlp_engine.dart';

/// A 3D point in the lab's model space (network layers along z, neurons
/// stacked along y).
class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;
}

/// Per-layer neuron flash state (forward activation flash / backward error
/// flash whose intensity is this layer's share of the gradient norm).
class LayerFlash {
  LayerFlash({required this.untilMs, required this.backward, required this.layerT});
  final int untilMs;
  final bool backward;
  final double layerT;
}

/// One travelling pulse along an edge. Backward pulses carry their edge's
/// real gradient share as [mag].
class PulseSpec {
  PulseSpec({
    required this.from,
    required this.to,
    required this.delayMs,
    required this.durMs,
    required this.backward,
    this.mag = 1.0,
  });
  final Vec3 from, to;
  final int delayMs, durMs;
  final bool backward;
  final double mag;
}

/// Everything the painter needs to draw one frame of the live network.
class NeuralScene {
  NeuralScene({
    required this.net,
    required this.neurons,
    required this.edges,
    required this.waves,
    required this.flashes,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.showGradients,
    required this.gradEdge,
    required this.gradAbsMax,
    required this.labels,
    this.surfaceColors,
    this.surfaceVisible = true,
  });

  final MLP net;
  final List<List<Vec3>> neurons; // [layer][idx]
  final List<List<({int i, int j})>> edges; // per weight layer
  final List<({int startMs, List<PulseSpec> pulses, int totalMs})> waves;
  final List<LayerFlash?> flashes; // per layer
  final double yaw, pitch, zoom;
  final bool showGradients; // edge colors = real gradients, not weights
  final List<List<double>> gradEdge; // per layer, per edge |grad|
  final double gradAbsMax;
  final List<String> labels;
  final List<List<Color>>? surfaceColors; // [row][col] decision plane
  final bool surfaceVisible;
}

class Neural3DPainter extends CustomPainter {
  Neural3DPainter(this.scene, this.nowMs);

  final NeuralScene scene;
  final int nowMs;

  static const _layerGap = 4.2;
  static const _neuronGap = 1.35;
  static const _focal = 900.0;
  static const _dist = 26.0;

  static Color layerColor(int l, int L) {
    if (l == 0) return const Color(0xFFFFD166); // input — gold
    if (l == L) return const Color(0xFFFF5CA8); // output — magenta
    return const Color(0xFF5AC8FA); // hidden — sky
  }

  /// Lay out neurons for a network of [sizes]: layer planes along z, neurons
  /// stacked along y, centred on the origin.
  static List<List<Vec3>> buildNeurons(List<int> sizes) {
    final L = sizes.length - 1;
    final xOff = (L * _layerGap) / 2;
    final out = <List<Vec3>>[];
    for (var l = 0; l <= L; l++) {
      final n = sizes[l];
      final z = l * _layerGap - xOff;
      final ySpan = (n - 1) * _neuronGap;
      out.add([
        for (var i = 0; i < n; i++) Vec3(0, ySpan / 2 - i * _neuronGap, z),
      ]);
    }
    return out;
  }

  /// All (i, j) weight edges per layer, in row-major order matching net.W.
  static List<List<({int i, int j})>> buildEdges(List<int> sizes) {
    final L = sizes.length - 1;
    return [
      for (var l = 0; l < L; l++)
        [
          for (var i = 0; i < sizes[l]; i++)
            for (var j = 0; j < sizes[l + 1]; j++) (i: i, j: j),
        ],
    ];
  }

  /// Orbit-rotate a model point, then perspective-project to canvas space.
  Offset _project(Vec3 p, Size size) {
    var x = p.x, y = p.y, z = p.z;
    final cy = math.cos(scene.yaw), sy = math.sin(scene.yaw);
    final rx = x * cy + z * sy;
    final rz = -x * sy + z * cy;
    final cp = math.cos(scene.pitch), sp = math.sin(scene.pitch);
    final ry = y * cp - rz * sp;
    final rz2 = y * sp + rz * cp;
    final zc = rz2 + _dist;
    final s = _focal / math.max(4.0, zc) * scene.zoom;
    return Offset(size.width / 2 + rx * s, size.height / 2 - ry * s);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final net = scene.net;
    final L = net.L;

    // ---- decision surface plane (below the network) ----
    final surf = scene.surfaceColors;
    if (scene.surfaceVisible && surf != null && surf.isNotEmpty) {
      const planeY = -5.6, half = 2.9;
      final rows = surf.length, cols = surf[0].length;
      final cell = (half * 2) / (cols - 1);
      final fill = Paint();
      for (var r = 0; r < rows - 1; r++) {
        for (var c = 0; c < cols - 1; c++) {
          final x0 = -half + c * cell, x1 = x0 + cell;
          final z0 = -half + r * cell, z1 = z0 + cell;
          final p0 = _project(Vec3(x0, planeY, z0), size);
          final p1 = _project(Vec3(x1, planeY, z0), size);
          final p2 = _project(Vec3(x1, planeY, z1), size);
          final p3 = _project(Vec3(x0, planeY, z1), size);
          final path = Path()
            ..moveTo(p0.dx, p0.dy)
            ..lineTo(p1.dx, p1.dy)
            ..lineTo(p2.dx, p2.dy)
            ..lineTo(p3.dx, p3.dy)
            ..close();
          fill.color = surf[r][c];
          canvas.drawPath(path, fill);
        }
      }
    }

    // ---- edges: weights, or REAL gradients while the backward wave flows ----
    final edgePaint = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var l = 0; l < L; l++) {
      final nOut = net.sizes[l + 1];
      for (var k = 0; k < scene.edges[l].length; k++) {
        final e = scene.edges[l][k];
        final pa = _project(scene.neurons[l][e.i], size);
        final pb = _project(scene.neurons[l + 1][e.j], size);
        Color col;
        if (scene.showGradients &&
            l < scene.gradEdge.length && k < scene.gradEdge[l].length) {
          final t =
              (scene.gradEdge[l][k] / math.max(1e-12, scene.gradAbsMax)).clamp(0.0, 1.0);
          col = Color.fromRGBO(
              (48 + 153 * t).round(), (36 + 15 * t).round(), (26 + 10 * t).round(), 0.9);
        } else {
          final w = net.W[l][e.i * nOut + e.j];
          final t = (w.abs() / math.max(0.4, _weightScaleCache)).clamp(0.0, 1.0);
          col = w >= 0
              ? Color.fromRGBO((56 + 15 * t).round(), (115 + 31 * t).round(), 255, 0.85)
              : Color.fromRGBO((140 + 102 * t).round(), (31 + 20 * t).round(), 56, 0.85);
        }
        edgePaint.color = col;
        canvas.drawLine(pa, pb, edgePaint);
      }
    }

    // ---- pulses: cyan forward data flow / orange backward gradient flow ----
    final pulseCore = Paint();
    final pulseHalo = Paint();
    for (final wave in scene.waves) {
      final elapsed = nowMs - wave.startMs;
      for (final p in wave.pulses) {
        final t = (elapsed - p.delayMs) / p.durMs;
        if (t < 0 || t > 1) continue;
        final x = p.from.x + (p.to.x - p.from.x) * t;
        final y = p.from.y + (p.to.y - p.from.y) * t;
        final z = p.from.z + (p.to.z - p.from.z) * t;
        final pos = _project(Vec3(x, y, z), size);
        final radius = 2.4 * p.mag;
        pulseHalo.color = p.backward ? const Color(0x33FF7A3C) : const Color(0x333FD6FF);
        canvas.drawCircle(pos, radius, pulseHalo);
        pulseCore.color = p.backward ? const Color(0xFFFF7A3C) : const Color(0xFF3FD6FF);
        canvas.drawCircle(pos, radius * 0.55, pulseCore);
      }
    }

    _paintNeurons(canvas, size);
    _paintLabels(canvas, size);
  }

  void _paintNeurons(Canvas canvas, Size size) {
    final net = scene.net;
    for (var l = 0; l < scene.neurons.length; l++) {
      final flash = scene.flashes.length > l ? scene.flashes[l] : null;
      final flashing = flash != null && nowMs < flash.untilMs;
      for (var i = 0; i < scene.neurons[l].length; i++) {
        final pos = _project(scene.neurons[l][i], size);
        final act = net.lastActs[l][i].abs().clamp(0.0, 1.0);
        final intensity = flashing
            ? 0.3 + 1.5 * math.max(act, flash.backward ? flash.layerT : 0.0)
            : 0.22 + 0.6 * act;
        var col = layerColor(l, net.L);
        if (flashing && flash.backward) col = const Color(0xFFFF5533);
        final radius = 8.0 * scene.zoom.clamp(0.6, 1.6);
        canvas.drawCircle(pos, radius * 0.62, Paint()
          ..color = col.withValues(alpha: (0.10 * intensity).clamp(0.04, 0.5)));
        canvas.drawCircle(pos, radius * 0.34, Paint()
          ..color = col.withValues(alpha: (0.35 * intensity).clamp(0.15, 0.95)));
        canvas.drawCircle(pos, radius * 0.2, Paint()
          ..color = Color.lerp(col, Colors.white, (0.25 * intensity).clamp(0.0, 0.7))!
              .withValues(alpha: (0.5 + 0.5 * intensity).clamp(0.4, 1.0)));
      }
    }
  }

  void _paintLabels(Canvas canvas, Size size) {
    final tp = TextPainter(textDirection: TextDirection.ltr, textAlign: TextAlign.center);
    for (var l = 0; l < scene.labels.length && l < scene.neurons.length; l++) {
      final first = scene.neurons[l][0];
      final anchor = _project(Vec3(first.x, first.y + 1.15, first.z), size);
      tp.text = TextSpan(
        text: scene.labels[l],
        style: const TextStyle(
            fontSize: 11, color: Color(0xFFB4C3E1), fontWeight: FontWeight.w600),
      );
      tp.layout();
      tp.paint(canvas, anchor - Offset(tp.width / 2, 0));
    }
  }

  /// Cached max |weight| so edge brightness stays comparable between updates.
  static double _weightScaleCache = 0.5;

  static void refreshWeightScale(MLP net) {
    var mx = 1e-6;
    for (var l = 0; l < net.L; l++) {
      for (final w in net.W[l]) {
        mx = math.max(mx, w.abs());
      }
    }
    _weightScaleCache = math.max(0.4, mx);
  }

  @override
  bool shouldRepaint(Neural3DPainter oldDelegate) => true;
}
