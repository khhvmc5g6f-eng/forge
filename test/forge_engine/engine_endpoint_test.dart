import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/forge_engine/engine_endpoint.dart';

void main() {
  group('parsePairing', () {
    test('forge:// with token, name and port', () {
      final p = parsePairing('forge://192.168.1.20:9000?token=abc123&name=Studio%20Mac')!;
      expect(p.endpoint.host, '192.168.1.20');
      expect(p.endpoint.port, 9000);
      expect(p.endpoint.tls, isFalse);
      expect(p.endpoint.name, 'Studio Mac');
      expect(p.token, 'abc123');
    });

    test('forge:// tls=1 means https; default port 8765', () {
      final p = parsePairing('forge://engine.example.com?tls=1&token=t')!;
      expect(p.endpoint.tls, isTrue);
      expect(p.endpoint.baseUri.scheme, 'https');
      expect(p.endpoint.port, 8765);
    });

    test('https URL without a port means 443, http bare host means 8765', () {
      expect(parsePairing('https://forge.example.com')!.endpoint.port, 443);
      expect(parsePairing('127.0.0.1')!.endpoint.port, 8765);
      expect(parsePairing('localhost:1234')!.endpoint.port, 1234);
      expect(parsePairing('http://10.0.0.5:8765')!.token, isNull);
    });

    test('rejects junk', () {
      expect(parsePairing(''), isNull);
      expect(parsePairing('ftp://x'), isNull);
      expect(parsePairing('http://'), isNull);
      expect(parsePairing('host:99999'), isNull);
      // half-typed addresses must not connect to something unintended
      expect(parsePairing('127.0.0.'), isNull);
      expect(parsePairing('127.0.0'), isNull);
      expect(parsePairing('300.1.1.1'), isNull);
      expect(parsePairing('host..name'), isNull);
      expect(parsePairing('-bad.example.com'), isNull);
      expect(parsePairing('127.0.0.1:8791')!.endpoint.host, '127.0.0.1');
      expect(parsePairing('my-mac.local:8765')!.endpoint.host, 'my-mac.local');
      expect(parsePairing('http://[::1]:8765')!.endpoint.isLoopback, isTrue);
    });

    test('round trips through toPairingString', () {
      const e = EngineEndpoint(host: 'mac.local', port: 8765, name: 'Mac');
      final back = parsePairing(e.toPairingString(token: 'tok'))!;
      expect(back.endpoint, e);
      expect(back.token, 'tok');
      const t = EngineEndpoint(host: 'x.example.com', port: 443, tls: true);
      expect(parsePairing(t.toPairingString())!.endpoint, t);
    });
  });

  group('transport safety', () {
    test('loopback is safe for secrets, LAN http is not', () {
      expect(const EngineEndpoint(host: '127.0.0.1', port: 1).safeForSecrets, isTrue);
      expect(const EngineEndpoint(host: 'localhost', port: 1).safeForSecrets, isTrue);
      const lan = EngineEndpoint(host: '192.168.1.5', port: 1);
      expect(lan.safeForSecrets, isFalse);
      expect(lan.isPrivateNetwork, isTrue);
      expect(lan.isCleartextOffDevice, isTrue);
      expect(const EngineEndpoint(host: '192.168.1.5', port: 1, tls: true).safeForSecrets, isTrue);
      expect(const EngineEndpoint(host: '8.8.8.8', port: 1).isPrivateNetwork, isFalse);
      expect(const EngineEndpoint(host: '172.20.0.1', port: 1).isPrivateNetwork, isTrue);
      expect(const EngineEndpoint(host: '172.40.0.1', port: 1).isPrivateNetwork, isFalse);
    });
  });
}
