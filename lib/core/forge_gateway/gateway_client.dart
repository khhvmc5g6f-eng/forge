import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'gateway_models.dart';

enum GatewayStatus { disconnected, connecting, connected, error }

/// Observes a running Forge gateway (`/forge/state` polling plus the
/// `/forge/events` SSE stream). Read-only: it never sends keys or prompts.
/// Nothing is requested until [connect] is called.
class GatewayClient extends ChangeNotifier {
  GatewayClient({http.Client Function()? clientFactory, this.pollInterval = const Duration(seconds: 2)})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  final Duration pollInterval;

  GatewayStatus status = GatewayStatus.disconnected;
  String? error;
  GatewayState? state;
  final List<GatewayEvent> events = [];
  static const maxEvents = 300;

  http.Client? _client;
  Timer? _timer;
  StreamSubscription<String>? _sse;
  Uri? _base;
  int _lastSeq = 0;

  Future<void> connect(String baseUrl) async {
    await disconnect();
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _fail('Enter a full address such as http://127.0.0.1:8765');
      return;
    }
    _base = uri;
    _client = _clientFactory();
    status = GatewayStatus.connecting;
    error = null;
    notifyListeners();
    await _poll();
    if (status == GatewayStatus.connected) {
      _timer = Timer.periodic(pollInterval, (_) => _poll());
      unawaited(_listen());
    }
  }

  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    await _sse?.cancel();
    _sse = null;
    _client?.close();
    _client = null;
    if (status != GatewayStatus.disconnected) {
      status = GatewayStatus.disconnected;
      notifyListeners();
    }
  }

  Future<void> _poll() async {
    final client = _client;
    if (client == null) return;
    try {
      final r = await client.get(_base!.resolve('/forge/state')).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) throw 'Gateway answered HTTP ${r.statusCode}';
      state = GatewayState.fromJson((jsonDecode(r.body) as Map).cast<String, dynamic>());
      status = GatewayStatus.connected;
      error = null;
      notifyListeners();
    } catch (e) {
      if (_client == null) return; // disconnected meanwhile
      _fail('$e');
    }
  }

  Future<void> _listen() async {
    final client = _client;
    if (client == null) return;
    try {
      final req = http.Request('GET', _base!.resolve('/forge/events'))
        ..headers['accept'] = 'text/event-stream'
        ..headers['last-event-id'] = '$_lastSeq';
      final res = await client.send(req);
      _sse = res.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
        _onLine,
        onError: (_) {},
        cancelOnError: true,
      );
    } catch (_) {
      // State polling still reports connectivity; the event feed is best-effort.
    }
  }

  void _onLine(String line) {
    if (!line.startsWith('data:')) return;
    try {
      final e = GatewayEvent.tryParse(jsonDecode(line.substring(5).trim()));
      if (e == null || e.seq <= _lastSeq) return;
      _lastSeq = e.seq;
      events.add(e);
      if (events.length > maxEvents) events.removeAt(0);
      notifyListeners();
    } catch (_) {
      // Ignore malformed frames rather than inventing data.
    }
  }

  void _fail(String message) {
    status = GatewayStatus.error;
    error = message;
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(disconnect());
    super.dispose();
  }
}
