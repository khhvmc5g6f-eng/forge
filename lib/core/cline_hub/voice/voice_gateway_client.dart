import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/hub_client.dart' show HubTransport;
import '../protocol/hub_endpoint.dart';
import 'voice_messages.dart';

typedef VoiceTransportFactory = Future<HubTransport> Function(Uri uri);

Future<HubTransport> _ioTransport(Uri uri) async {
  final socket = await WebSocket.connect(
    uri.toString(),
  ).timeout(const Duration(seconds: 8));
  socket.pingInterval = const Duration(seconds: 20);
  return _IoTransport(socket);
}

class _IoTransport implements HubTransport {
  _IoTransport(this._s);
  final WebSocket _s;
  @override
  Stream<String> get incoming => _s.where((e) => e is String).cast<String>();
  @override
  void send(String frame) => _s.add(frame);
  @override
  Future<void> close() => _s.close();
}

/// Connection to the Mac's voice gateway. Audio and text go up; state, transcript,
/// interpretation and text-to-speak come back. No intelligence lives here.
class VoiceGatewayClient {
  VoiceGatewayClient({VoiceTransportFactory? transportFactory})
    : _factory = transportFactory ?? _ioTransport;

  final VoiceTransportFactory _factory;
  final _messages = StreamController<VoiceServerMessage>.broadcast();
  HubTransport? _transport;
  StreamSubscription<String>? _sub;
  bool _connected = false;
  String? lastError;

  Stream<VoiceServerMessage> get messages => _messages.stream;
  bool get isConnected => _connected;

  /// Uses the endpoint's host/secret with the gateway path and [port] (default 8790).
  Future<bool> connect(
    HubEndpoint endpoint, {
    int? port,
    String mode = 'command',
    String verbosity = 'normal',
  }) async {
    await disconnect();
    final base = port == null
        ? endpoint
        : HubEndpoint.tryParse(
            '${endpoint.baseUrl.scheme}://${endpoint.baseUrl.host}:$port',
            roomSecret: endpoint.roomSecret,
          )!;
    try {
      final t = await _factory(base.webSocketUriFor('/voice'));
      _transport = t;
      _sub = t.incoming.listen(
        (raw) => _messages.add(VoiceServerMessage.parse(raw)),
        onError: (Object e) => _lost('$e'),
        onDone: () => _lost('connection closed'),
        cancelOnError: true,
      );
      _connected = true;
      lastError = null;
      _send({'type': 'hello', 'mode': mode, 'verbosity': verbosity});
      return true;
    } catch (e) {
      lastError = e is TimeoutException ? 'timed out' : '$e';
      _connected = false;
      return false;
    }
  }

  void _lost(String why) {
    lastError = why;
    _connected = false;
    _sub?.cancel();
    _sub = null;
    _transport = null;
    if (!_messages.isClosed) {
      _messages.add(VoiceErrorMessage('Voice connection lost: $why'));
    }
  }

  bool _send(Map<String, Object?> frame) {
    final t = _transport;
    if (t == null || !_connected) return false;
    t.send(encodeVoiceFrame(frame));
    return true;
  }

  /// [wav] must be a 16 kHz mono 16-bit WAV file's bytes.
  bool sendUtterance(Uint8List wav, {int? audioMs}) => _send({
    'type': 'utterance',
    'wav': base64Encode(wav),
    'audioMs': ?audioMs,
  });
  bool sendText(String text) => _send({'type': 'text', 'text': text});
  bool speechStart() => _send({'type': 'speech_start'});
  bool speechFinished() => _send({'type': 'speech_finished'});
  bool configure({String? mode, String? verbosity}) =>
      _send({'type': 'set', 'mode': ?mode, 'verbosity': ?verbosity});

  Future<void> disconnect() async {
    _connected = false;
    await _sub?.cancel();
    _sub = null;
    final t = _transport;
    _transport = null;
    await t?.close();
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
  }

  /// Reachability probe of the gateway's `/health`.
  static Future<String?> probe(HubEndpoint endpoint, {int? port}) async {
    final uri =
        (port == null ? endpoint.baseUrl : endpoint.baseUrl.replace(port: port))
            .replace(path: '/health');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
      return res.statusCode == 200 ? null : 'server answered ${res.statusCode}';
    } catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }
}
