import 'dart:async';
import 'dart:convert';

import 'package:forge/core/cline_hub/protocol/hub_client.dart';
import 'package:forge/core/cline_hub/protocol/hub_endpoint.dart';

class FakeTransport implements HubTransport {
  final _in = StreamController<String>.broadcast();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String frame) =>
      sent.add(jsonDecode(frame) as Map<String, dynamic>);

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }

  void push(Map<String, Object?> msg) => _in.add(jsonEncode(msg));
  void drop() => _in.close();
}

/// Factory that hands out a fresh [FakeTransport] per connect and can fail on demand.
class FakeNetwork {
  final transports = <FakeTransport>[];
  int failNext = 0;

  Future<HubTransport> connect(HubEndpoint e) async {
    if (failNext > 0) {
      failNext--;
      throw const FormatException('connection refused');
    }
    final t = FakeTransport();
    transports.add(t);
    return t;
  }

  FakeTransport get current => transports.last;
}

HubEndpoint endpoint([String url = 'http://127.0.0.1:8787']) =>
    HubEndpoint.tryParse(url)!;
