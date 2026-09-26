import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../core/neural/mlp_engine.dart';
import 'neural_3d_painter.dart';

/// FORGE · NEURAL LAB — a native, live 3D visualisation of a neural network
/// actually learning: forward-pass data flow, backward-pass gradient flow
/// (real per-edge ∂L/∂w), and a full live analytics dock. Ported from the
/// MLclass `live-3d-nn` web lab onto Forge's desktop/phone/tablet shell.
/// The engine (`lib/core/neural/mlp_engine.dart`) is pure Dart and
/// gradient-check tested; this panel is pure Flutter — no web views, no 3D
/// packages, no plugins.
class NeuralLabPanel extends StatefulWidget {
  const NeuralLabPanel({super.key});

  @override
  State<NeuralLabPanel> createState() => _NeuralLabPanelState();
}

class _NeuralLabPanelState extends State<NeuralLabPanel>
    with SingleTickerProviderStateMixin {
  // ---- experiment config ----
  String _datasetName = 'spiral';
  double _noise = 0.15;
  int _dataSeed = 7;
  String _archText = '8, 8';
  List<int> _arch = const [8, 8];
  String _activation = 'tanh';
  String _optimizer = 'adam';
  String _features = 'extended';
  double _lr = 0.01;
  int _batch = 8;
  int _trainSpeed = 6;
  double _waveSpeed = 1.0;
  bool _lossLog = false;

  // ---- run state ----
  bool _playing = false;
  int _step = 0;
  int _epoch = 0;
  int _probeIdx = 0;
  late MLP _net;
  List<NnPoint> _train = const [];
  List<NnPoint> _test = const [];
  List<({int step, double trainLoss, double testLoss, double acc})> _history = [];
  List<double> _gradNorms = const [];
  List<int> _confusion = const [0, 0, 0, 0]; // TP, FP, FN, TN
  double _trainLoss = 0, _testLoss = 0, _acc = 0;
  String _phase = 'idle';

  // ---- scene state ----
  List<List<Vec3>> _neurons = const [];
  List<List<({int i, int j})>> _edges = const [];
  final List<({int startMs, List<PulseSpec> pulses, int totalMs})> _waves = [];
  List<LayerFlash?> _flashes = const [];
  List<List<double>> _gradEdge = const [];
  double _gradAbsMax = 1e-12;
  int _gradUntilMs = 0; // edges show real gradients until this time
  double _yaw = 0.5, _pitch = 0.35, _zoom = 1.0;
  double _zoomAtGestureStart = 1.0;
  bool _autoRotate = false;
  bool _showSurface = true;
  List<List<Color>> _surfaceColors = const [];

  late final Ticker _ticker;
  int _lastFrameMs = 0;
  int _lastAnalyticsStep = -10000;

  static const _waveBaseDurMs = 550;
  static const _maxWaves = 4;

  @override
  void initState() {
    super.initState();
    _rebuildData();
    _rebuildNetwork();
    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _rebuildData() {
    final pts = makeDataset(_datasetName, 400, _noise, _dataSeed);
    final split = splitTrainTest(pts, 0.25, _dataSeed + 1);
    _train = split['train']!;
    _test = split['test']!;
    _probeIdx = 0;
  }

  List<int> _parseArch(String text) {
    return text
        .split(RegExp(r'[,x\s]+'))
        .map((s) => int.tryParse(s))
        .where((n) => n != null && n >= 1 && n <= 12)
        .map((n) => n!)
        .toList()
        .take(6)
        .toList();
  }

  void _rebuildNetwork() {
    final nIn = _features == 'extended' ? 7 : 2;
    _net = MLP([nIn, ..._arch, 1],
        activation: _activation,
        optimizer: _optimizer,
        features: _features,
        lr: _lr,
        seed: 42);
    _neurons = Neural3DPainter.buildNeurons(_net.sizes);
    _edges = Neural3DPainter.buildEdges(_net.sizes);
    _flashes = List<LayerFlash?>.filled(_net.sizes.length, null);
    _gradEdge = List<List<double>>.generate(
        _net.L, (l) => List<double>.filled(_edges[l].length, 0), growable: false);
    _history = [];
    _step = 0;
    _epoch = 0;
    _gradNorms = [];
    _confusion = const [0, 0, 0, 0];
    _waves.clear();
    Neural3DPainter.refreshWeightScale(_net);
    _refreshAnalytics();
    _refreshSurface();
  }

  void _regenerateData() {
    _dataSeed = (math.Random().nextDouble() * 1e6).toInt();
    _rebuildData();
    _rebuildNetwork();
  }

  // ---- one training step: SGD/Adam batch + real-gradient waves ----
  void _oneTrainStep(int nowMs) {
    if (_train.isEmpty) return;
    _probeIdx = (_probeIdx + 1) % _train.length;
    final probe = _train[_probeIdx];
    final rand = math.Random();
    final batch = <NnPoint>[
      for (var i = 0; i < _batch; i++) _train[rand.nextInt(_train.length)]
    ];
    final res = _net.trainStep(batch, probeSample: probe);
    _step++;
    _epoch = (_step * _batch) ~/ _train.length;
    _gradNorms = res.gradNorms;

    // Real per-edge |gradient| snapshot — drives the backward wave.
    var gMax = 1e-12;
    for (var l = 0; l < _net.L; l++) {
      for (var k = 0; k < _edges[l].length; k++) {
        final e = _edges[l][k];
        final g = (_net.dW[l][e.i * _net.sizes[l + 1] + e.j] / batch.length).abs();
        _gradEdge[l][k] = g;
        if (g > gMax) gMax = g;
      }
    }
    _gradAbsMax = gMax;
    Neural3DPainter.refreshWeightScale(_net);
    _launchWaves(nowMs);
  }

  void _launchWaves(int nowMs) {
    if (_waves.length >= _maxWaves) return;
    final L = _net.L;
    final durMs = (_waveBaseDurMs / math.max(0.05, _waveSpeed)).round();
    final reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    // Forward wave: rank edges by |weight|.
    final fwd = <PulseSpec>[];
    // Backward wave: rank edges by REAL |gradient|, scale pulses by share.
    final bwd = <PulseSpec>[];
    final gMax = math.max(1e-12, _gradAbsMax);
    for (var l = 0; l < L; l++) {
      final budget = reduceMotion
          ? math.max(6, (math.max(24, 380 ~/ L) * 0.2).floor())
          : math.min(_edges[l].length, math.max(24, 380 ~/ L));
      final ranked = <({int k, double s})>[
        for (var k = 0; k < _edges[l].length; k++)
          (k: k, s: _net.W[l][_edgeW(l, k) ?? 0].abs())
      ];
      // forward: by |weight|
      final byW = [...ranked]..sort((a, b) => b.s.compareTo(a.s));
      for (var k = 0; k < math.min(budget, byW.length); k++) {
        final e = _edges[l][byW[k].k];
        fwd.add(PulseSpec(
          from: _neurons[l][e.i],
          to: _neurons[l + 1][e.j],
          delayMs: l * durMs,
          durMs: durMs,
          backward: false,
        ));
      }
      // backward: by |grad|
      final byG = <({int k, double s})>[
        for (var k = 0; k < _edges[l].length; k++) (k: k, s: _gradEdge[l][k])
      ]..sort((a, b) => b.s.compareTo(a.s));
      for (var k = 0; k < math.min(budget, byG.length); k++) {
        final e = _edges[l][byG[k].k];
        bwd.add(PulseSpec(
          from: _neurons[l + 1][e.j],
          to: _neurons[l][e.i],
          delayMs: (L - 1 - l) * durMs,
          durMs: durMs,
          backward: true,
          mag: 0.6 + 1.4 * (byG[k].s / gMax).clamp(0.0, 1.0),
        ));
      }
      // layer flashes: forward on arrival; backward intensity = grad share.
      final gradMax = _gradNorms.isEmpty
          ? 0.0
          : _gradNorms.reduce(math.max);
      _flashes[l + 1] = LayerFlash(
        untilMs: nowMs + (l * durMs + durMs * 2),
        backward: false,
        layerT: 0.4,
      );
      _flashes[l] = LayerFlash(
        untilMs: nowMs + ((L - 1 - l) * durMs + durMs * 2 + L * durMs ~/ 2),
        backward: true,
        layerT: gradMax > 0
            ? 0.25 + 0.75 * ((_gradNorms.isEmpty ? 0 : _gradNorms[l]) / gradMax)
            : 0.3,
      );
    }
    final totalFwd = L * durMs + durMs;
    _waves.add((
      startMs: nowMs,
      pulses: fwd,
      totalMs: totalFwd,
    ));
    final bwdStart = nowMs + (L * durMs * 0.55).round();
    _waves.add((
      startMs: bwdStart,
      pulses: bwd,
      totalMs: L * durMs + durMs,
    ));
    _gradUntilMs = bwdStart + L * durMs + durMs;
  }

  int? _edgeW(int l, int k) {
    final e = _edges[l][k];
    final nOut = _net.sizes[l + 1];
    return e.i * nOut + e.j;
  }

  // ---- frame loop ----
  void _onTick(Duration elapsed) {
    final nowMs = elapsed.inMilliseconds;
    if (_lastFrameMs == 0) _lastFrameMs = nowMs;
    final dtMs = (nowMs - _lastFrameMs).clamp(0, 50);
    _lastFrameMs = nowMs;

    if (_playing) {
      for (var i = 0; i < _trainSpeed; i++) {
        _oneTrainStep(nowMs);
      }
      if (_step - _lastAnalyticsStep >= math.max(4, _trainSpeed * 2)) {
        _lastAnalyticsStep = _step;
        _refreshAnalytics();
        _refreshSurface();
      }
    }

    // prune expired waves + flashes
    _waves.removeWhere((w) => nowMs - w.startMs > w.totalMs);
    if (_autoRotate) _yaw += dtMs * 0.00012;

    // Rebuild only when something is visibly changing — a paused, wave-free,
    // non-rotating scene is static, so we skip the frame rebuild entirely
    // (also lets `pumpAndSettle` settle in tests and saves battery).
    final animating = _playing || _waves.isNotEmpty || _autoRotate;
    if (mounted && animating) setState(() {});
  }

  void _refreshAnalytics() {
    if (_train.isEmpty) return;
    final tl = _net.lossAndAcc(_train).loss;
    final te = _net.lossAndAcc(_test);
    _trainLoss = tl;
    _testLoss = te.loss;
    _acc = te.acc;
    _history.add((step: _step, trainLoss: tl, testLoss: te.loss, acc: te.acc));
    if (_history.length > 600) _history.removeAt(0);
    var tp2 = 0, fp2 = 0, fn2 = 0, tn2 = 0;
    for (final p in _test) {
      final q = _net.predict(p.x, p.y) >= 0.5 ? 1 : 0;
      if (q == 1 && p.label == 1) tp2++;
      if (q == 1 && p.label == 0) fp2++;
      if (q == 0 && p.label == 1) fn2++;
      if (q == 0 && p.label == 0) tn2++;
    }
    _confusion = [tp2, fp2, fn2, tn2];
    _phase = _computePhase();
  }

  // Training phase, readable as text (never colour alone).
  String _computePhase() {
    final h = _history;
    if (h.isEmpty || h.last.step == 0) return 'idle';
    final last = h.last;
    if (h.length < 20) return 'learning';
    final n200 = h.length > 200 ? h.sublist(h.length - 200) : h;
    final accChange = (n200.last.acc - n200.first.acc).abs();
    final n300 = h.length > 300 ? h.sublist(h.length - 300) : h;
    final trainDrop = n300.first.trainLoss - n300.last.trainLoss;
    final testRise = n300.last.testLoss > n300.first.testLoss + 0.02;
    var minTrain = h.first.trainLoss;
    for (final d in h) {
      if (d.trainLoss < minTrain) minTrain = d.trainLoss;
    }
    if (last.trainLoss > minTrain * 1.5 && minTrain < 0.6) return 'diverging';
    if (trainDrop > 0.02 && testRise) return 'overfit';
    if (last.acc > 0.90 && accChange < 0.005) return 'converged';
    if (last.acc <= 0.90 && accChange < 0.005) return 'plateaued';
    return 'learning';
  }

  void _refreshSurface() {
    if (!_showSurface) return;
    const n = 24;
    _surfaceColors = [
      for (var r = 0; r < n; r++)
        [
          for (var c = 0; c < n; c++) _surfaceCellColor(n, r, c),
        ],
    ];
  }

  Color _surfaceCellColor(int n, int r, int c) {
    final x = (c / (n - 1)) * 2 - 1;
    final y = 1 - (r / (n - 1)) * 2;
    final p = _net.predict(x, y);
    if (p >= 0.5) {
      final t = (p - 0.5) * 2;
      return Color.fromRGBO((28 + 60 * t).round(), 90, (150 + 90 * t).round(), 0.35);
    } else {
      final t = (0.5 - p) * 2;
      return Color.fromRGBO((120 + 70 * t).round(), 60, 90, 0.35);
    }
  }

  // ---- scene assembly ----
  NeuralScene _buildScene(int nowMs) {
    final L = _net.L;
    return NeuralScene(
      net: _net,
      neurons: _neurons,
      edges: _edges,
      waves: _waves,
      flashes: _flashes,
      yaw: _yaw,
      pitch: _pitch,
      zoom: _zoom,
      showGradients: nowMs < _gradUntilMs,
      gradEdge: _gradEdge,
      gradAbsMax: _gradAbsMax,
      labels: [
        for (var l = 0; l <= L; l++)
          l == 0
              ? (_features == 'extended' ? 'INPUT · 7 features' : 'INPUT (x, y)')
              : l == L ? 'OUTPUT ŷ' : 'HIDDEN $l',
      ],
      surfaceColors: _surfaceColors,
      surfaceVisible: _showSurface,
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 760;
    final analytics = _AnalyticsDock(
      history: _history,
      gradNorms: _gradNorms,
      confusion: _confusion,
      test: _test,
      net: _net,
      trainLoss: _trainLoss,
      testLoss: _testLoss,
      acc: _acc,
      phase: _phase,
      epoch: _epoch,
      lossLog: _lossLog,
      onToggleLog: () => setState(() => _lossLog = !_lossLog),
    );
    return Column(
      children: [
        _buildToolbar(context),
        Expanded(
          child: wide
              ? Row(children: [
                  Expanded(child: _buildStage(context)),
                  SizedBox(width: 340, child: analytics),
                ])
              : Column(children: [
                  Expanded(child: _buildStage(context)),
                  SizedBox(height: 320, child: analytics),
                ]),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(children: [
        _toolbarLabel('Dataset'),
        _dropdown<String>(_datasetName, ['spiral', 'moons', 'circles', 'xor', 'gauss'],
            (v) => setState(() { _datasetName = v; _rebuildData(); _rebuildNetwork(); })),
        _toolbarLabel('Noise'),
        SizedBox(
          width: 90,
          child: Slider(
            value: _noise, min: 0, max: 0.5,
            onChanged: (v) => setState(() => _noise = v),
            onChangeEnd: (_) { _rebuildData(); _rebuildNetwork(); },
          ),
        ),
        Text(_noise.toStringAsFixed(2), style: const TextStyle(fontSize: 11)),
        _toolbarLabel('Hidden'),
        SizedBox(
          width: 64,
          child: TextField(
            controller: TextEditingController(text: _archText),
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            onSubmitted: (text) {
              final parsed = _parseArch(text);
              if (parsed.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Use e.g. "8, 8" — 1–12 neurons, up to 6 layers')));
                return;
              }
              setState(() { _arch = parsed; _archText = parsed.join(', '); });
              _rebuildNetwork();
            },
          ),
        ),
        _toolbarLabel('Features'),
        _dropdown<String>(_features, const ['extended', 'basic'],
            (v) => setState(() { _features = v; _rebuildNetwork(); })),
        _toolbarLabel('Activation'),
        _dropdown<String>(_activation, const ['tanh', 'relu'],
            (v) => setState(() { _activation = v; _rebuildNetwork(); })),
        _toolbarLabel('Optimizer'),
        _dropdown<String>(_optimizer, const ['adam', 'sgd'],
            (v) => setState(() { _optimizer = v; _rebuildNetwork(); })),
        _toolbarLabel('LR'),
        _dropdown<double>(_lr, const [0.001, 0.003, 0.01, 0.03, 0.1, 0.3, 1.0],
            (v) => setState(() { _lr = v; _net.lr = v; })),
        _toolbarLabel('Batch'),
        _dropdown<int>(_batch, const [1, 4, 8, 16, 32],
            (v) => setState(() => _batch = v)),
        _toolbarLabel('Speed'),
        SizedBox(
          width: 70,
          child: Slider(
            value: _waveSpeed, min: 0.25, max: 3,
            onChanged: (v) => setState(() => _waveSpeed = v),
          ),
        ),
        SizedBox(
          width: 90,
          child: Slider(
            value: _trainSpeed.toDouble(), min: 1, max: 40,
            divisions: 39,
            label: '${_trainSpeed}x',
            onChanged: (v) => setState(() => _trainSpeed = v.round()),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton(
          onPressed: () => setState(() => _playing = !_playing),
          child: Text(_playing ? 'Pause' : 'Train'),
        ),
        OutlinedButton(onPressed: _stepOnce, child: const Text('Step')),
        OutlinedButton(onPressed: _regen, child: const Text('Data')),
        OutlinedButton(
          onPressed: () => setState(() => _showSurface = !_showSurface),
          style: OutlinedButton.styleFrom(
              backgroundColor: _showSurface ? Theme.of(context).colorScheme.primaryContainer : null),
          child: const Text('Surface'),
        ),
        OutlinedButton(
          onPressed: () => setState(() => _autoRotate = !_autoRotate),
          style: OutlinedButton.styleFrom(
              backgroundColor: _autoRotate ? Theme.of(context).colorScheme.primaryContainer : null),
          child: const Text('Rotate'),
        ),
        OutlinedButton(onPressed: _showHelp, child: const Text('?')),
      ]),
    );
  }

  void _stepOnce() {
    _oneTrainStep(_lastFrameMs);
    _refreshAnalytics();
    _refreshSurface();
    setState(() {});
  }

  void _regen() {
    setState(_regenerateData);
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('What am I looking at?'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• Cyan waves — the forward pass: data flowing in → out for a real sample.'),
            Text('• Orange waves — the backward pass: real per-edge gradients flowing out → in.'),
            Text('• Edge colour — weight sign (blue positive, red negative); during the backward '
                'wave it shows gradient magnitude instead.'),
            Text('• Drag to orbit, pinch or scroll to zoom. Charts update live while training.'),
          ],
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _buildStage(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          setState(() => _zoom = (_zoom * (event.scrollDelta.dy > 0 ? 0.95 : 1.05)).clamp(0.4, 2.5));
        }
      },
      child: GestureDetector(
        onScaleStart: (_) => _zoomAtGestureStart = _zoom,
        onScaleUpdate: (s) => setState(() {
          if (s.pointerCount <= 1) {
            // single pointer (touch drag or mouse drag): orbit the camera
            _yaw += s.focalPointDelta.dx * 0.008;
            _pitch = (_pitch + s.focalPointDelta.dy * 0.008).clamp(-1.4, 1.4);
          } else {
            // pinch: zoom relative to where the gesture started
            _zoom = (_zoomAtGestureStart * s.scale).clamp(0.4, 2.5);
          }
        }),
        child: ClipRect(
          child: CustomPaint(
            painter: Neural3DPainter(_buildScene(_lastFrameMs), _lastFrameMs),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }

  Widget _toolbarLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600),
        ),
      );

  Widget _dropdown<T>(T value, List<T> values, ValueChanged<T> onChanged) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: values.contains(value) ? value : values.first,
        items: [for (final v in values) DropdownMenuItem(value: v, child: Text('$v'))],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
        style: const TextStyle(fontSize: 12, color: Colors.black87),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

/// The analytics dock: live metrics, loss curves (with a log-scale toggle),
/// decision-boundary map, gradient bars and the confusion matrix.
class _AnalyticsDock extends StatelessWidget {
  const _AnalyticsDock({
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

