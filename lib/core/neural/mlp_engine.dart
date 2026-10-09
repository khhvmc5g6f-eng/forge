import 'dart:math' as math;
import 'dart:typed_data';

/// Live Neural Network Lab — pure-Dart engine (Flutter-free), ported from the
/// verified JavaScript engine in MLclass `live-3d-nn/index.html`. Everything
/// below is deterministic (seeded RNG) and unit-tested in
/// `test/core/neural/mlp_engine_test.dart`, including a numerical gradient
/// check against backprop and convergence thresholds on every dataset.

/// Deterministic mulberry32 RNG (bit-exact port of the JS lab's generator).
class Mulberry32 {
  Mulberry32(int seed) : _a = seed & 0xFFFFFFFF;

  int _a;

  static int _mul32(int a, int b) {
    final ah = (a >>> 16) & 0xFFFF, al = a & 0xFFFF;
    final bh = (b >>> 16) & 0xFFFF, bl = b & 0xFFFF;
    return ((((ah * bl + al * bh) & 0xFFFF) << 16) | ((al * bl) & 0xFFFF)) & 0xFFFFFFFF;
  }

  double next() {
    _a = (_a + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _mul32(_a ^ (_a >>> 15), _a | 1);
    t = ((t + _mul32(t ^ (t >>> 7), t | 61)) ^ t) & 0xFFFFFFFF;
    return ((t ^ (t >>> 14)) & 0xFFFFFFFF) / 4294967296;
  }

  /// Standard-normal draw via Box–Muller.
  double gauss() {
    final u = math.max(next(), 1e-12), v = next();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }
}

/// One training/testing sample in the 2D classification datasets.
class NnPoint {
  const NnPoint(this.x, this.y, this.label);
  final double x;
  final double y;
  final int label;
}

/// The lab's datasets — the same families the MLclass Section 6 notebooks and
/// the JS lab use (spiral, two moons, concentric circles, XOR blobs,
/// gaussians), all roughly normalised to [-1, 1] and class-balanced.
List<NnPoint> makeDataset(String name, int n, double noise, int seed) {
  final rand = Mulberry32(seed);
  final pts = <NnPoint>[];
  void add(double x, double y, int label) => pts.add(NnPoint(x, y, label));
  n = math.max(20, (n ~/ 2) * 2);

  if (name == 'spiral') {
    // Inner radius 0.25 keeps the arms separable under noise — with smaller
    // radii the labels become genuinely ambiguous near the centre (measured:
    // a 24x24 net reaches 100% train while test caps ~85% — pure label noise).
    for (var i = 0; i < n; i++) {
      final cls = i % 2;
      final r = (i / n) * 0.75 + 0.25;
      final t = 1.75 * (i / n) * 2 * math.pi + cls * math.pi;
      add(r * math.sin(t) + rand.gauss() * noise * 0.3,
          r * math.cos(t) + rand.gauss() * noise * 0.3, cls);
    }
  } else if (name == 'moons') {
    for (var i = 0; i < n; i++) {
      final cls = i % 2;
      final t = rand.next() * math.pi;
      final x = cls == 0 ? math.cos(t) : 1 - math.cos(t);
      final y = cls == 0 ? math.sin(t) : 0.5 - math.sin(t);
      add((x - 0.5) + rand.gauss() * noise * 0.6,
          (y - 0.25) * 1.6 + rand.gauss() * noise * 0.6, cls);
    }
  } else if (name == 'circles') {
    for (var i = 0; i < n; i++) {
      final cls = i % 2;
      final r = cls == 0 ? rand.next() * 0.35 : 0.65 + rand.next() * 0.3;
      final t = rand.next() * 2 * math.pi;
      add(r * math.sin(t) + rand.gauss() * noise * 0.4,
          r * math.cos(t) + rand.gauss() * noise * 0.4, cls);
    }
  } else if (name == 'xor') {
    // Exact class balance: mirror x when the quadrant label doesn't match the
    // class slot (mirroring preserves the XOR label structure).
    for (var i = 0; i < n; i++) {
      final cls = i % 2;
      var x = rand.next() * 1.8 - 0.9;
      var y = rand.next() * 1.8 - 0.9;
      x += x > 0 ? 0.1 : -0.1;
      y += y > 0 ? 0.1 : -0.1;
      final label = (x > 0) != (y > 0) ? 1 : 0;
      if (label != cls) x = -x;
      add(x + rand.gauss() * noise * 0.3, y + rand.gauss() * noise * 0.3, cls);
    }
  } else {
    // gauss
    for (var i = 0; i < n; i++) {
      final cls = i % 2;
      final cx = cls == 0 ? -0.5 : 0.5, cy = cls == 0 ? -0.4 : 0.4;
      add(cx + rand.gauss() * (0.22 + noise * 0.6),
          cy + rand.gauss() * (0.22 + noise * 0.6), cls);
    }
  }
  return pts;
}

/// Deterministic train/test split (25% held out by default).
Map<String, List<NnPoint>> splitTrainTest(
    List<NnPoint> pts, double testFraction, int seed) {
  final rand = Mulberry32(seed);
  final shuffled = List<NnPoint>.of(pts);
  for (var i = shuffled.length - 1; i > 0; i--) {
    final j = (rand.next() * (i + 1)).toInt();
    final tmp = shuffled[i];
    shuffled[i] = shuffled[j];
    shuffled[j] = tmp;
  }
  final nTest = (shuffled.length * testFraction).floor();
  return {
    'train': shuffled.sublist(0, shuffled.length - nTest),
    'test': shuffled.sublist(shuffled.length - nTest),
  };
}

/// A from-scratch MLP: tanh/ReLU hidden units, sigmoid output, BCE loss,
/// mini-batch SGD or Adam. The same architecture the JS lab's gradient-check
/// suite verified to ~1e-10 against numerical differentiation.
class MLP {
  MLP(this.sizes, {
    this.activation = 'tanh',
    this.optimizer = 'adam',
    this.lr = 0.01,
    this.features = 'basic',
    int seed = 42,
  }) {
    _build(seed);
  }

  final List<int> sizes; // [nIn, h1, ..., hL, 1]
  final String activation; // 'tanh' | 'relu'
  final String optimizer; // 'adam' | 'sgd'
  final String features; // 'basic' | 'extended'
  double lr;

  late int L;
  late List<Float64List> W, b, dW, db;
  late List<Float64List> mW, vW, mb, vb;
  int _adamT = 0;
  late List<Float64List> lastActs;

  void _build(int seed) {
    L = sizes.length - 1;
    final rand = Mulberry32(seed);
    W = []; b = []; dW = []; db = [];
    mW = []; vW = []; mb = []; vb = [];
    for (var l = 0; l < L; l++) {
      final nIn = sizes[l], nOut = sizes[l + 1];
      final scale = math.sqrt(2 / (nIn + nOut)) * 1.6; // Xavier-ish
      final w = Float64List(nIn * nOut);
      for (var i = 0; i < w.length; i++) {
        w[i] = (rand.next() * 2 - 1) * scale;
      }
      W.add(w);
      b.add(Float64List(nOut));
      dW.add(Float64List(nIn * nOut));
      db.add(Float64List(nOut));
      mW.add(Float64List(nIn * nOut));
      vW.add(Float64List(nIn * nOut));
      mb.add(Float64List(nOut));
      vb.add(Float64List(nOut));
    }
    lastActs = [for (final n in sizes) Float64List(n)];
  }

  int get paramCount {
    var c = 0;
    for (var l = 0; l < L; l++) {
      c += W[l].length + b[l].length;
    }
    return c;
  }

  /// Input feature mapping: raw (x, y), or the TensorFlow-Playground-style
  /// engineered features that let students watch feature engineering collapse
  /// the spiral problem.
  List<double> featurize(double x, double y) {
    if (features == 'extended') {
      return [x, y, x * x, y * y, x * y, math.sin(x), math.sin(y)];
    }
    return [x, y];
  }

  List<String> featureNames() => features == 'extended'
      ? const ['x', 'y', 'x²', 'y²', 'x·y', 'sin x', 'sin y']
      : const ['x', 'y'];

  double _act(double z) {
    if (activation == 'relu') return z > 0 ? z : 0;
    final c = z.clamp(-20.0, 20.0); // avoid exp overflow / inf-over-inf NaN
    return (math.exp(c) - math.exp(-c)) / (math.exp(c) + math.exp(-c));
  }
  double _actD(double z, double a) =>
      activation == 'relu' ? (z > 0 ? 1 : 0) : 1 - a * a;

  /// Forward pass for one sample; fills [lastActs] and returns p(label=1).
  double forward(NnPoint sample) {
    final f = featurize(sample.x, sample.y);
    for (var i = 0; i < lastActs[0].length && i < f.length; i++) {
      lastActs[0][i] = f[i];
    }
    for (var l = 0; l < L; l++) {
      final nIn = sizes[l], nOut = sizes[l + 1];
      final w = W[l], bb = b[l], src = lastActs[l], dst = lastActs[l + 1];
      for (var j = 0; j < nOut; j++) {
        var z = bb[j];
        for (var i = 0; i < nIn; i++) {
          z += src[i] * w[i * nOut + j];
        }
        dst[j] = l == L - 1 ? 1 / (1 + math.exp(-z)) : _act(z);
      }
    }
    return lastActs[L][0];
  }

  double predict(double x, double y) => forward(NnPoint(x, y, 1));

  /// Full-set BCE loss + accuracy.
  LossAcc lossAndAcc(List<NnPoint> pts) {
    var loss = 0.0, correct = 0;
    for (final p in pts) {
      final q = forward(p).clamp(1e-9, 1 - 1e-9);
      loss += -(p.label * math.log(q) + (1 - p.label) * math.log(1 - q));
      if ((q >= 0.5 ? 1 : 0) == p.label) correct++;
    }
    return LossAcc(
        pts.isEmpty ? 0 : loss / pts.length,
        pts.isEmpty ? 0 : correct / pts.length);
  }

  /// One mini-batch step. Accumulates per-weight gradients into [dW]/[db]
  /// (the visualiser reads these to draw the real gradient flow), updates
  /// parameters via Adam or SGD, and returns the batch loss + per-layer
  /// gradient norms.
  TrainStepResult trainStep(List<NnPoint> batch, {NnPoint? probeSample}) {
    for (var l = 0; l < L; l++) {
      dW[l].fillRange(0, dW[l].length, 0);
      db[l].fillRange(0, db[l].length, 0);
    }

    var loss = 0.0;
    for (final s in batch) {
      // forward, storing zs and activations for backprop
      final acts = <Float64List>[Float64List.fromList(featurize(s.x, s.y))];
      final zs = <Float64List?>[null];
      for (var l = 0; l < L; l++) {
        final nIn = sizes[l], nOut = sizes[l + 1];
        final src = acts[l];
        final z = Float64List(nOut), aOut = Float64List(nOut);
        for (var j = 0; j < nOut; j++) {
          var v = b[l][j];
          for (var i = 0; i < nIn; i++) {
            v += src[i] * W[l][i * nOut + j];
          }
          z[j] = v;
          aOut[j] = l == L - 1 ? 1 / (1 + math.exp(-v)) : _act(v);
        }
        zs.add(z);
        acts.add(aOut);
      }
      final p = acts[L][0];
      final t = s.label.toDouble();
      final q = p.clamp(1e-9, 1 - 1e-9);
      loss += -(t * math.log(q) + (1 - t) * math.log(1 - q));

      // backward
      var delta = Float64List(1)..[0] = p - t;
      for (var l = L - 1; l >= 0; l--) {
        final nIn = sizes[l], nOut = sizes[l + 1];
        final src = acts[l];
        for (var j = 0; j < nOut; j++) {
          db[l][j] += delta[j];
          for (var i = 0; i < nIn; i++) {
            dW[l][i * nOut + j] += src[i] * delta[j];
          }
        }
        if (l > 0) {
          final prev = Float64List(nIn);
          for (var i = 0; i < nIn; i++) {
            var v = 0.0;
            for (var j = 0; j < nOut; j++) {
              v += W[l][i * nOut + j] * delta[j];
            }
            prev[i] = v * _actD(zs[l]![i], acts[l][i]);
          }
          delta = prev;
        }
      }
    }

    final m = batch.length;
    final gradNorms = List<double>.filled(L, 0);
    for (var l = 0; l < L; l++) {
      var sq = 0.0;
      for (var k = 0; k < W[l].length; k++) {
        final g = dW[l][k] / m;
        sq += g * g;
      }
      // g is already the mean gradient (dW/m), so the per-layer L2 norm needs
      // no second division by the batch size. (Bit-consistent with the web
      // export in web_lab/index.html, which applies the same fix.)
      gradNorms[l] = math.sqrt(sq);
    }

    if (optimizer == 'adam') {
      const b1 = 0.9, b2 = 0.999, eps = 1e-8;
      _adamT++;
      final bc1 = 1 - math.pow(b1, _adamT);
      final bc2 = 1 - math.pow(b2, _adamT);
      for (var l = 0; l < L; l++) {
        for (var k = 0; k < W[l].length; k++) {
          final g = dW[l][k] / m;
          mW[l][k] = b1 * mW[l][k] + (1 - b1) * g;
          vW[l][k] = b2 * vW[l][k] + (1 - b2) * g * g;
          W[l][k] -= lr * (mW[l][k] / bc1) / (math.sqrt(vW[l][k] / bc2) + eps);
        }
        for (var k = 0; k < b[l].length; k++) {
          final g = db[l][k] / m;
          mb[l][k] = b1 * mb[l][k] + (1 - b1) * g;
          vb[l][k] = b2 * vb[l][k] + (1 - b2) * g * g;
          b[l][k] -= lr * (mb[l][k] / bc1) / (math.sqrt(vb[l][k] / bc2) + eps);
        }
      }
    } else {
      for (var l = 0; l < L; l++) {
        for (var k = 0; k < W[l].length; k++) {
          W[l][k] -= lr * dW[l][k] / m;
        }
        for (var k = 0; k < b[l].length; k++) {
          b[l][k] -= lr * db[l][k] / m;
        }
      }
    }

    if (probeSample != null) forward(probeSample);
    return TrainStepResult(loss / m, gradNorms);
  }
}

class LossAcc {
  const LossAcc(this.loss, this.acc);
  final double loss;
  final double acc;
}

class TrainStepResult {
  const TrainStepResult(this.loss, this.gradNorms);
  final double loss;
  final List<double> gradNorms;
}
