import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_gateway/gateway_client.dart';

/// Opt-in: FORGE_LIVE_GATEWAY=http://127.0.0.1:8765 flutter test test/forge_gateway/live_gateway_test.dart
void main() {
  final url = Platform.environment['FORGE_LIVE_GATEWAY'];
  test('live gateway state', () async {
    final g = GatewayClient();
    await g.connect(url!);
    expect(g.status, GatewayStatus.connected, reason: g.error);
    expect(g.state, isNotNull);
    await g.disconnect();
  }, skip: url == null ? 'set FORGE_LIVE_GATEWAY' : false);
}
