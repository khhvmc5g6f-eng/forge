import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge/core/cloud/cloud_models.dart';
import 'package:forge/core/cloud/cloud_wallet_service.dart';
import 'package:forge/core/cloud/forge_cloud_client.dart';
import 'package:forge/core/security/secrets_store.dart';

Map<String, dynamic> _money(String nanos) => {'nanos': nanos, 'currency': 'GBP'};

Map<String, dynamic> _row(int i, DateTime at) => {
      'id': 'u$i',
      'model': 'dep-a',
      'inputTokens': 10 * i,
      'outputTokens': i,
      'cost': _money('${1000000 * i}'),
      'at': at.toUtc().toIso8601String(),
    };

ForgeCloudClient _client(
  MockClient mock,
  SecretsStore store, {
  String base = 'https://cloud.example.invalid',
}) =>
    ForgeCloudClient(
      baseUrl: Uri.parse(base),
      secretsStore: store,
      httpClient: mock,
    );

void main() {
  group('parseForgeCloudUrl', () {
    test('unset, blank or invalid means not configured', () {
      expect(parseForgeCloudUrl(null), isNull);
      expect(parseForgeCloudUrl('  '), isNull);
      expect(parseForgeCloudUrl('nonsense'), isNull);
      expect(parseForgeCloudUrl('ftp://x.example.invalid'), isNull);
      expect(parseForgeCloudUrl('https://x.example.invalid')!.host,
          'x.example.invalid');
    });
  });

  group('NotConfiguredCloudWalletService', () {
    test('reports not configured and refuses to refresh', () async {
      const service = NotConfiguredCloudWalletService();
      expect(service.isConfigured, isFalse);
      await expectLater(
          service.refresh(), throwsA(isA<ForgeCloudNotConfiguredException>()));
      expect(const ForgeCloudNotConfiguredException().toString(),
          'Forge Cloud not configured');
    });
  });

  group('ForgeCloudWalletService', () {
    test('combines balance and usage, newest first, capped at ten rows',
        () async {
      final store = InMemorySecretsStore();
      await store.write(forgeCloudTokenSecretRef, 'tok');
      final base = DateTime.utc(2026, 10, 1);
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/wallet/balance') {
          return http.Response(
              jsonEncode({'balance': _money('42500000000')}), 200);
        }
        if (request.url.path == '/api/usage/summary') {
          return http.Response(
            jsonEncode({
              'monthToDateSpend': _money('7500000000'),
              'recent': [
                for (var i = 1; i <= 12; i++) _row(i, base.add(Duration(hours: i))),
              ],
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final fixedNow = DateTime.utc(2026, 10, 11);
      final service =
          ForgeCloudWalletService(_client(mock, store), clock: () => fixedNow);

      final snapshot = await service.refresh();

      expect(service.isConfigured, isTrue);
      expect(snapshot.balance.format(), '£42.50');
      expect(snapshot.monthToDateSpend.format(), '£7.50');
      expect(snapshot.recentUsage.length, 10);
      expect(snapshot.recentUsage.first.id, 'u12');
      expect(snapshot.recentUsage.last.id, 'u3');
      expect(snapshot.fetchedAt, fixedNow);
      expect(requests.every((r) => r.headers['Authorization'] == 'Bearer tok'),
          isTrue);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
    });

    test('without a stored token it fails as unauthenticated and makes no request',
        () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        return http.Response('{}', 200);
      });
      final service =
          ForgeCloudWalletService(_client(mock, InMemorySecretsStore()));

      await expectLater(
        service.refresh(),
        throwsA(isA<ForgeCloudException>()
            .having((e) => e.isUnauthenticated, 'isUnauthenticated', isTrue)),
      );
      expect(calls, 0);
    });

    test('maps HTTP errors and invalid JSON to ForgeCloudException', () async {
      final store = InMemorySecretsStore();
      await store.write(forgeCloudTokenSecretRef, 'tok');

      final unauthorised = _client(
          MockClient((_) async => http.Response('no', 401)), store);
      await expectLater(
        unauthorised.getWalletBalance(),
        throwsA(isA<ForgeCloudException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );

      final garbage = _client(
          MockClient((_) async => http.Response('<html>', 200)), store);
      await expectLater(
          garbage.getWalletBalance(), throwsA(isA<ForgeCloudException>()));
    });

    test('a base URL with a path prefix keeps the prefix', () async {
      final store = InMemorySecretsStore();
      await store.write(forgeCloudTokenSecretRef, 'tok');
      late Uri seen;
      final mock = MockClient((request) async {
        seen = request.url;
        return http.Response(jsonEncode({'models': []}), 200);
      });
      final catalogue = await _client(mock, store,
              base: 'https://cloud.example.invalid/forge/')
          .getModelCatalogue();
      expect(seen.path, '/forge/api/models');
      expect(catalogue.models, isEmpty);
    });
  });

  group('ForgeCloudClient device code and estimate', () {
    test('issue and redeem do not send an Authorization header', () async {
      final seen = <http.Request>[];
      final mock = MockClient((request) async {
        seen.add(request);
        if (request.url.path == '/api/forge-device-code-issue') {
          return http.Response(
            jsonEncode({
              'deviceCode': 'dc',
              'userCode': 'ABCD',
              'verificationUri': 'https://example.invalid/device',
              'expiresInSeconds': 600,
              'intervalSeconds': 1,
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'status': 'pending'}), 200);
      });
      final client = _client(mock, InMemorySecretsStore());

      final issue = await client.issueDeviceCode();
      final redeem = await client.redeemDeviceCode(issue.deviceCode);

      expect(redeem.status, DeviceCodeStatus.pending);
      expect(seen.every((r) => !r.headers.containsKey('Authorization')), isTrue);
      expect(jsonDecode(seen.last.body), {'deviceCode': 'dc'});
    });

    test('pollDeviceCode waits while pending, then stores the token on approval',
        () async {
      final store = InMemorySecretsStore();
      var redeemCalls = 0;
      final mock = MockClient((request) async {
        redeemCalls++;
        if (redeemCalls < 3) {
          return http.Response(jsonEncode({'status': 'pending'}), 200);
        }
        return http.Response(
            jsonEncode({'status': 'approved', 'accessToken': 'new-token'}), 200);
      });
      final waits = <Duration>[];
      final status = await _client(mock, store).pollDeviceCode(
        const DeviceCodeIssue(
          deviceCode: 'dc',
          userCode: 'ABCD',
          verificationUri: 'https://example.invalid/device',
          expiresInSeconds: 600,
          intervalSeconds: 5,
        ),
        delay: (d) async => waits.add(d),
      );

      expect(status, DeviceCodeStatus.approved);
      expect(redeemCalls, 3);
      expect(waits, [const Duration(seconds: 5), const Duration(seconds: 5)]);
      expect(await store.read(forgeCloudTokenSecretRef), 'new-token');
    });

    test('pollDeviceCode gives up as expired when the window elapses', () async {
      final mock = MockClient(
          (_) async => http.Response(jsonEncode({'status': 'pending'}), 200));
      final status = await _client(mock, InMemorySecretsStore()).pollDeviceCode(
        const DeviceCodeIssue(
          deviceCode: 'dc',
          userCode: 'ABCD',
          verificationUri: 'https://example.invalid/device',
          expiresInSeconds: 10,
          intervalSeconds: 5,
        ),
        delay: (_) async {},
      );
      expect(status, DeviceCodeStatus.expired);
    });

    test('estimateCost posts nano-free token counts and parses Money', () async {
      final store = InMemorySecretsStore();
      await store.write(forgeCloudTokenSecretRef, 'tok');
      late http.Request seen;
      final mock = MockClient((request) async {
        seen = request;
        return http.Response(jsonEncode({'estimate': _money('1234567890')}), 200);
      });

      final estimate = await _client(mock, store).estimateCost(
        const CostEstimateRequest(
            model: 'm1', inputTokens: 1000, outputTokens: 200),
      );

      expect(seen.method, 'POST');
      expect(seen.url.path, '/api/estimate');
      expect(jsonDecode(seen.body),
          {'model': 'm1', 'inputTokens': 1000, 'outputTokens': 200});
      expect(estimate.estimate.nanos, BigInt.from(1234567890));
    });
  });
}
