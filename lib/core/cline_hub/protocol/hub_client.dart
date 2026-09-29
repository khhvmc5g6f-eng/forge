import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'hub_endpoint.dart';
import 'messages.dart';

enum ConnectionStatus { disconnected, connecting, connected, reconnecting }

/// Minimal socket abstraction so the client can be tested without a network.
abstract class HubTransport {
  Stream<String> get incoming;
  void send(String frame);
  Future<void> close();
}

typedef TransportFactory = Future<HubTransport> Function(HubEndpoint endpoint);

class IoHubTransport implements HubTransport {
  IoHubTransport._(this._socket);
  final WebSocket _socket;

  static Future<HubTransport> connect(HubEndpoint endpoint) async {
    final socket = await WebSocket.connect(
      endpoint.webSocketUri.toString(),
      headers: {'Origin': endpoint.origin},
    ).timeout(const Duration(seconds: 10));
    socket.pingInterval = const Duration(seconds: 20);
    return IoHubTransport._(socket);
  }

  @override
  Stream<String> get incoming =>
      _socket.where((e) => e is String).cast<String>();

  @override
  void send(String frame) => _socket.add(frame);

  @override
  Future<void> close() => _socket.close();
}

/// Connection to the Cline hub with bounded exponential-backoff reconnects.
class HubClient {
  HubClient({
    TransportFactory? transportFactory,
    Random? random,
    this.maxReconnectAttempts = 8,
  }) : _factory = transportFactory ?? IoHubTransport.connect,
       _random = random ?? Random();

  final TransportFactory _factory;
  final Random _random;
  final int maxReconnectAttempts;

  final _messages = StreamController<HubMessage>.broadcast();
  final _status = StreamController<ConnectionStatus>.broadcast();
  ConnectionStatus _current = ConnectionStatus.disconnected;
  HubTransport? _transport;
  StreamSubscription<String>? _sub;
  HubEndpoint? _endpoint;
  bool _wantConnected = false;
  int _attempt = 0;
  Timer? _retryTimer;

  Stream<HubMessage> get messages => _messages.stream;
  Stream<ConnectionStatus> get statusStream => _status.stream;
  ConnectionStatus get status => _current;
  String? lastError;

  /// Delay before reconnect attempt [attempt] (1-based): 1s,2s,4s… capped at 30s, with jitter.
  static Duration backoff(int attempt, {double jitter = 0}) {
    final base = min(30, pow(2, attempt - 1).toInt());
    return Duration(milliseconds: (base * 1000 * (1 + jitter * 0.25)).round());
  }

  Future<void> connect(HubEndpoint endpoint) async {
    _endpoint = endpoint;
    _wantConnected = true;
    _attempt = 0;
    await _open(initial: true);
  }

  Future<void> _open({required bool initial}) async {
    final endpoint = _endpoint;
    if (endpoint == null || !_wantConnected) return;
    _set(initial ? ConnectionStatus.connecting : ConnectionStatus.reconnecting);
    try {
      final t = await _factory(endpoint);
      if (!_wantConnected) {
        await t.close();
        return;
      }
      _transport = t;
      _attempt = 0;
      lastError = null;
      _sub = t.incoming.listen(
        (raw) => _messages.add(HubMessage.parse(raw)),
        onError: (Object e) => _onLost('$e'),
        onDone: () => _onLost('connection closed'),
        cancelOnError: true,
      );
      _set(ConnectionStatus.connected);
      send({'type': 'ready'});
    } catch (e) {
      _onLost(_describe(e), initialFailure: initial);
    }
  }

  static String _describe(Object e) {
    if (e is TimeoutException) return 'timed out';
    if (e is WebSocketException) return e.message;
    if (e is SocketException) return e.message;
    return '$e';
  }

  void _onLost(String reason, {bool initialFailure = false}) {
    lastError = reason;
    _sub?.cancel();
    _sub = null;
    _transport = null;
    if (!_wantConnected) {
      _set(ConnectionStatus.disconnected);
      return;
    }
    if (initialFailure || _attempt >= maxReconnectAttempts) {
      _wantConnected = false;
      _set(ConnectionStatus.disconnected);
      return;
    }
    _attempt++;
    _set(ConnectionStatus.reconnecting);
    _retryTimer?.cancel();
    _retryTimer = Timer(
      backoff(_attempt, jitter: _random.nextDouble()),
      () => _open(initial: false),
    );
  }

  /// Returns false when not connected (the frame is not queued).
  bool send(Map<String, Object?> frame) {
    final t = _transport;
    if (t == null || _current != ConnectionStatus.connected) return false;
    t.send(jsonEncode(frame));
    return true;
  }

  Future<void> disconnect() async {
    _wantConnected = false;
    _retryTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    final t = _transport;
    _transport = null;
    await t?.close();
    _set(ConnectionStatus.disconnected);
  }

  void _set(ConnectionStatus s) {
    if (_current == s) return;
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
    await _status.close();
  }

  /// One-shot reachability probe of `/health` (a public route).
  static Future<String?> probe(HubEndpoint endpoint) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(endpoint.healthUri);
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
      if (res.statusCode == 200) return null;
      return 'server answered ${res.statusCode}';
    } catch (e) {
      return _describe(e);
    } finally {
      client.close(force: true);
    }
  }
}
