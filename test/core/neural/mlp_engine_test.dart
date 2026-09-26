import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/neural/mlp_engine.dart';

void main() {
  test('mulberry32 is deterministic and in range', () {
    final a = Mulberry32(7), b = Mulberry32(7);
    for (var i = 0; i < 100; i++) {
      final v = a.next();
      expect(v, b.next());
      expect(v, inExclusiveRange(0.0, 1.0));
    }
  });

  test('backprop gradients match numerical differentiation (tanh)', () {
    final net = MLP([2, 5, 4, 1], activation: 'tanh', optimizer: 'sgd', lr: 0.0, seed: 123);
    final batch = [
      const NnPoint(0.3, -0.7, 1),
      const NnPoint(-0.4, 0.55, 0),
      const NnPoint(0.8, 0.2, 0),
      const NnPoint(-0.1, -0.9, 1),
    ];
    const eps = 1e-5;
    var maxRelErr = 0.0;
    for (var l = 0; l < net.L; l++) {
      for (var k = 0; k < net.W[l].length; k++) {
        final orig = net.W[l][k];
        net.trainStep(batch); // lr = 0 → gradients accumulated, no update
        final g = net.dW[l][k] / batch.length;
        net.W[l][k] = orig;
        net.W[l][k] = orig + eps;
        final lp = net.lossAndAcc(batch).loss;
        net.W[l][k] = orig - eps;
        final lm = net.lossAndAcc(batch).loss;
        net.W[l][k] = orig;
        final num = (lp - lm) / (2 * eps);
        final rel = (g - num).abs() / (num.abs() + g.abs()).clamp(1e-8, 1e9);
        maxRelErr = math.max(maxRelErr, rel);
      }
    }
    expect(maxRelErr, lessThan(1e-3), reason: 'relative error $maxRelErr');
  });

  test('backprop gradients match numerical differentiation (ReLU)', () {
    final net = MLP([2, 6, 1], activation: 'relu', optimizer: 'sgd', lr: 0.0, seed: 9);
    final batch = [const NnPoint(0.5, 0.5, 1), const NnPoint(-0.5, -0.3, 0)];
    const eps = 1e-5;
    var maxRelErr = 0.0;
    for (var l = 0; l < net.L; l++) {
      for (var k = 0; k < net.W[l].length; k++) {
        final orig = net.W[l][k];
        net.trainStep(batch);
        final g = net.dW[l][k] / batch.length;
        net.W[l][k] = orig;
        net.W[l][k] = orig + eps;
        final lp = net.lossAndAcc(batch).loss;
        net.W[l][k] = orig - eps;
        final lm = net.lossAndAcc(batch).loss;
        net.W[l][k] = orig;
        final num = (lp - lm) / (2 * eps);
        final rel = (g - num).abs() / (num.abs() + g.abs()).clamp(1e-8, 1e9);
        maxRelErr = math.max(maxRelErr, rel);
      }
    }
    expect(maxRelErr, lessThan(5e-3), reason: 'relative error $maxRelErr');
  });

  test('all datasets are balanced and bounded', () {
    for (final name in ['spiral', 'moons', 'circles', 'xor', 'gauss']) {
      final pts = makeDataset(name, 400, 0.15, 7);
      final c0 = pts.where((p) => p.label == 0).length;
      final c1 = pts.where((p) => p.label == 1).length;
      expect(c0, c1, reason: name);
      for (final p in pts) {
        expect(p.x.abs(), lessThan(2.5));
        expect(p.y.abs(), lessThan(2.5));
      }
    }
  });

  convergenceMain();
}

/// Builds a fixed-seed mini-batch sampler so training runs are reproducible.
List<NnPoint> _sampleBatch(List<NnPoint> train, Mulberry32 rand, int size) =>
    [for (var i = 0; i < size; i++) train[(rand.next() * train.length).toInt()]];

void convergenceMain() {
  test('spiral converges with Adam + engineered features', () {
    final pts = makeDataset('spiral', 400, 0.15, 7);
    final split = splitTrainTest(pts, 0.25, 8);
    final train = split['train']!, test = split['test']!;
    final net = MLP([7, 8, 8, 1],
        activation: 'tanh', optimizer: 'adam', features: 'extended', lr: 0.01, seed: 3);
    final startLoss = net.lossAndAcc(train).loss;
    var loss = startLoss;
    final rand = Mulberry32(11);
    for (var step = 0; step < 6000; step++) {
      loss = net.trainStep(_sampleBatch(train, rand, 16)).loss;
    }
    final acc = net.lossAndAcc(test).acc;
    expect(loss, lessThan(startLoss * 0.3), reason: 'loss $startLoss -> $loss');
    expect(acc, greaterThan(0.9), reason: 'accuracy ${acc * 100}%');
  });

  test('moons, circles, xor and gauss all learn (Adam)', () {
    for (final name in ['moons', 'circles', 'xor', 'gauss']) {
      final pts = makeDataset(name, 400, 0.15, 7);
      final split = splitTrainTest(pts, 0.25, 8);
      final train = split['train']!, test = split['test']!;
      final net = MLP([7, 8, 8, 1],
          activation: 'tanh', optimizer: 'adam', features: 'extended', lr: 0.01, seed: 3);
      final rand = Mulberry32(11);
      for (var step = 0; step < 2500; step++) {
        net.trainStep(_sampleBatch(train, rand, 16));
      }
      final acc = net.lossAndAcc(test).acc;
      expect(acc, greaterThan(0.85), reason: '$name accuracy ${acc * 100}%');
    }
  });

  test('plain SGD still converges on moons', () {
    final pts = makeDataset('moons', 400, 0.15, 7);
    final split = splitTrainTest(pts, 0.25, 8);
    final train = split['train']!, test = split['test']!;
    final net = MLP([2, 10, 8, 1],
        activation: 'tanh', optimizer: 'sgd', features: 'basic', lr: 0.1, seed: 3);
    final rand = Mulberry32(11);
    for (var step = 0; step < 1500; step++) {
      net.trainStep(_sampleBatch(train, rand, 16));
    }
    final acc = net.lossAndAcc(test).acc;
    expect(acc, greaterThan(0.85), reason: 'accuracy ${acc * 100}%');
  });

  test('paramCount is correct', () {
    final net = MLP([2, 8, 8, 1], activation: 'tanh', optimizer: 'adam', lr: 0.03);
    expect(net.paramCount, 105); // (2*8+8)+(8*8+8)+(8*1+1)
  });

  test('engineered features beat raw (x, y) on spiral', () {
    final pts = makeDataset('spiral', 400, 0.15, 7);
    final split = splitTrainTest(pts, 0.25, 8);
    final train = split['train']!, test = split['test']!;
    double run(String features, int nIn) {
      final net = MLP([nIn, 8, 8, 1],
          activation: 'tanh', optimizer: 'adam', features: features, lr: 0.01, seed: 3);
      final rand = Mulberry32(11);
      for (var step = 0; step < 6000; step++) {
        net.trainStep(_sampleBatch(train, rand, 16));
      }
      return net.lossAndAcc(test).acc;
    }
    final rawAcc = run('basic', 2);
    final extAcc = run('extended', 7);
    expect(extAcc, greaterThan(rawAcc),
        reason: 'raw ${(rawAcc * 100).toStringAsFixed(1)}% vs '
            'engineered ${(extAcc * 100).toStringAsFixed(1)}%');
  });
}
