import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/forge_engine.dart';

import '../../forge_engine/fake_engine.dart';

/// Records engine actions instead of sending them.
class RecordingClient extends EngineClient {
  RecordingClient(this.log) : super(endpoint: const EngineEndpoint(host: '127.0.0.1', port: 1));
  final List<String> log;

  EngineActionResult _ok(String entry) {
    log.add(entry);
    return const EngineActionResult(ok: true, message: 'applied');
  }

  @override
  Future<EngineActionResult> addKey({required String providerId, required String name, required String secret, int? priority}) async =>
      _ok('addKey $providerId $name $secret ${priority ?? '-'}');
  @override
  Future<EngineActionResult> testKey(String keyId) async => _ok('testKey $keyId');
  @override
  Future<EngineActionResult> setKeyEnabled(String keyId, bool enabled) async => _ok('setKeyEnabled $keyId $enabled');
  @override
  Future<EngineActionResult> setKeyPriority(String keyId, int priority) async => _ok('setKeyPriority $keyId $priority');
  @override
  Future<EngineActionResult> removeKey(String keyId) async => _ok('removeKey $keyId');
  @override
  Future<EngineActionResult> setProviderEnabled(String providerId, bool enabled) async => _ok('setProviderEnabled $providerId $enabled');
  @override
  Future<EngineActionResult> circuitAction({required String level, required String id, required String action}) async => _ok('circuit $level $id $action');
  @override
  Future<EngineActionResult> acknowledge({String? id, bool all = false}) async => _ok('ack ${all ? 'all' : id}');
  @override
  Future<EngineActionResult> resumeGuard(String scope) async => _ok('resume $scope');
}

/// A connection that never touches the network.
class StubConnection extends EngineConnection {
  StubConnection({
    Map<String, dynamic>? stateJson,
    EngineLinkStatus status = EngineLinkStatus.connected,
    bool actions = true,
    EngineEndpoint endpoint = const EngineEndpoint(host: '127.0.0.1', port: 8765),
    bool eventsLive = true,
  }) {
    this.endpoint = endpoint;
    final json = stateJson ?? FakeEngine.baseState();
    debugApply(
      state: EngineState.fromJson(json),
      status: status,
      eventsLive: eventsLive,
      capabilities: actions
          ? const EngineCapabilities(version: '1', actions: {'key.add', 'key.test', 'key.update', 'key.remove', 'circuit.action', 'alert.ack', 'guard.resume'})
          : EngineCapabilities.none,
    );
    lastStateAt = DateTime.now();
  }

  final List<String> actionLog = [];
  final List<(EngineEndpoint, String?)> configured = [];

  @override
  Future<EngineActionResult> run(Future<EngineActionResult> Function(EngineClient c) action) => action(RecordingClient(actionLog));

  @override
  Future<void> configure(EngineEndpoint e, {String? token, bool persist = true}) async {
    configured.add((e, token));
    endpoint = e;
    notifyListeners();
  }

  @override
  Future<void> refresh() async {}
}

/// A clock the test advances by hand, so pulse windows and elapsed timers are deterministic.
class FakeClock {
  DateTime t = DateTime(2026, 10, 3, 12);
  DateTime call() => t;

  /// Moves this clock and the test's frame clock forward together.
  Future<void> elapse(WidgetTester tester, Duration d) async {
    t = t.add(d);
    await tester.pump(d);
  }
}

Future<void> pumpWithSize(WidgetTester tester, Widget child, {StubConnection? conn, Size size = const Size(1000, 900), List<Override> overrides = const [], FakeClock? clock}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = conn ?? StubConnection();
  await tester.pumpWidget(ProviderScope(
    overrides: [engineConnectionProvider.overrideWith((ref) => c), if (clock != null) engineClockProvider.overrideWithValue(clock.call), ...overrides],
    child: MaterialApp(theme: ThemeData(useMaterial3: true), home: Scaffold(body: child)),
  ));
  await tester.pump();
}

const phone = Size(390, 844);
const tablet = Size(820, 1180);
const desktop = Size(1440, 900);
