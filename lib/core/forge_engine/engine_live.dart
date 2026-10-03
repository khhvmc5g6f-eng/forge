import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine_connection.dart';
import 'engine_graph.dart';
import 'engine_models.dart';
import 'live_flow.dart';

/// Accumulates the live view models (in-flight requests, the engine graph)
/// from the connection's real event stream, so Live Flow and the Neural Lab
/// network show the recent past even if their screen was not open yet.
/// Listeners are notified only when an event or a new state snapshot arrives:
/// an idle engine produces no notifications and therefore no animation.
class EngineLive extends ChangeNotifier {
  EngineLive(this.connection, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    for (final e in connection.events) {
      _apply(e);
    }
    _sub = connection.eventStream.listen((e) {
      _apply(e);
      notifyListeners();
    });
    connection.addListener(_onConnection);
    _onConnection();
  }

  final EngineConnection connection;
  final DateTime Function() _clock;
  final LiveFlowModel flow = LiveFlowModel();
  final EngineGraph graph = EngineGraph();
  StreamSubscription<EngineEvent>? _sub;
  EngineState? _lastState;
  String? _endpointKey;
  bool _disposed = false;

  DateTime get now => _clock();

  void _apply(EngineEvent e) {
    flow.ingest(e, now: _clock());
    graph.applyEvent(e);
  }

  void _onConnection() {
    final ep = connection.endpoint?.toString();
    if (ep != _endpointKey) {
      // Pointed at a different engine: forget everything about the old one.
      _endpointKey = ep;
      flow.clear();
      graph.nodes.clear();
      graph.edges.clear();
      _lastState = null;
    }
    final s = connection.state;
    if (s != null && !identical(s, _lastState)) {
      _lastState = s;
      graph.applyState(s);
      flow.reconcile(s.active.map((a) => a.requestId).toSet(), now: _clock());
      notifyListeners();
    } else if (ep == null && _lastState == null) {
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    connection.removeListener(_onConnection);
    super.dispose();
  }
}
