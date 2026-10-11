import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge/core/cloud/cloud_models.dart';
import 'package:forge/core/cloud/money.dart';

void main() {
  group('Money', () {
    test('round trips as an integer string without precision loss', () {
      // Larger than 2^53, so a double would corrupt it.
      const raw = '9007199254740993123';
      final money = Money.fromJson({'nanos': raw, 'currency': 'GBP'});

      expect(money.nanos, BigInt.parse(raw));
      expect(money.toJson(), {'nanos': raw, 'currency': 'GBP'});
      final again = Money.fromJson(jsonDecode(jsonEncode(money.toJson())));
      expect(again, money);
    });

    test('rejects JSON numbers and decimals for the amount', () {
      expect(() => Money.fromJson({'nanos': 1500000000, 'currency': 'GBP'}),
          throwsFormatException);
      expect(() => Money.fromJson({'nanos': 1.5, 'currency': 'GBP'}),
          throwsFormatException);
      expect(() => Money.fromJson({'nanos': '1.5', 'currency': 'GBP'}),
          throwsFormatException);
      expect(() => Money.fromJson({'nanos': '', 'currency': 'GBP'}),
          throwsFormatException);
      expect(() => Money.fromJson({'nanos': '1'}), throwsFormatException);
      expect(() => Money.fromJson('1'), throwsFormatException);
    });

    test('formats GBP with integer rounding half away from zero', () {
      expect(Money(BigInt.from(12345000000), 'GBP').format(), '£12.35');
      expect(Money(BigInt.from(12344999999), 'GBP').format(), '£12.34');
      expect(Money(BigInt.zero, 'GBP').format(), '£0.00');
      expect(Money(BigInt.from(5000000), 'GBP').format(), '£0.01');
      expect(Money(BigInt.from(-12345000000), 'GBP').format(), '-£12.35');
      expect(Money(BigInt.from(1500000000), 'EUR').format(), 'EUR 1.50');
      expect(Money(BigInt.from(1500000000), 'GBP').format(decimals: 0), '£2');
    });

    test('adds same-currency amounts and rejects mixed currencies', () {
      final a = Money(BigInt.from(1), 'GBP');
      final b = Money(BigInt.from(2), 'GBP');
      expect((a + b).nanos, BigInt.from(3));
      expect(() => a + Money(BigInt.from(1), 'EUR'), throwsArgumentError);
      expect(Money.zero('GBP').nanos, BigInt.zero);
    });
  });

  group('cloud JSON models', () {
    final moneyJson = {'nanos': '2500000000', 'currency': 'GBP'};

    test('WalletBalance round trips', () {
      final json = {'balance': moneyJson, 'updatedAt': '2026-10-01T12:00:00.000Z'};
      final model = WalletBalance.fromJson(json);
      expect(model.balance.format(), '£2.50');
      expect(WalletBalance.fromJson(model.toJson()).balance, model.balance);
      expect(model.toJson()['balance'], moneyJson);
    });

    test('UsageSummary round trips with usage rows', () {
      final json = {
        'monthToDateSpend': moneyJson,
        'periodStart': '2026-10-01T00:00:00.000Z',
        'recent': [
          {
            'id': 'u1',
            'model': 'dep-a',
            'inputTokens': 120,
            'outputTokens': 30,
            'cost': moneyJson,
            'at': '2026-10-05T09:30:00.000Z',
          }
        ],
      };
      final model = UsageSummary.fromJson(json);
      expect(model.recent.single.inputTokens, 120);
      expect(model.recent.single.cost.nanos, BigInt.from(2500000000));
      final again = UsageSummary.fromJson(jsonDecode(jsonEncode(model.toJson())));
      expect(again.monthToDateSpend, model.monthToDateSpend);
      expect(again.recent.single.at, model.recent.single.at);
    });

    test('UsageRow rejects fractional token counts', () {
      expect(
        () => UsageRow.fromJson({
          'id': 'u1',
          'model': 'dep-a',
          'inputTokens': 1.5,
          'outputTokens': 3,
          'cost': moneyJson,
          'at': '2026-10-05T09:30:00.000Z',
        }),
        throwsFormatException,
      );
    });

    test('ModelCatalogue carries rates as Money and a deployment fallback', () {
      final catalogue = ModelCatalogue.fromJson({
        'models': [
          {
            'id': 'm1',
            'displayName': 'Model One',
            'inputRatePerMillion': moneyJson,
            'outputRatePerMillion': {'nanos': '7000000000', 'currency': 'GBP'},
          },
          {
            'id': 'm2',
            'displayName': 'Model Two',
            'deployment': 'dep-two',
            'inputRatePerMillion': moneyJson,
            'outputRatePerMillion': moneyJson,
            'contextWindowTokens': 128000,
          },
        ],
      });
      expect(catalogue.models.first.deploymentName, 'm1');
      expect(catalogue.models.last.deploymentName, 'dep-two');
      expect(catalogue.models.first.outputRatePerMillion.format(), '£7.00');
      final again = ModelCatalogue.fromJson(catalogue.toJson());
      expect(again.models.last.contextWindowTokens, 128000);
    });

    test('CostEstimateRequest and CostEstimate round trip', () {
      const request =
          CostEstimateRequest(model: 'm1', inputTokens: 1000, outputTokens: 200);
      final again = CostEstimateRequest.fromJson(request.toJson());
      expect(again.inputTokens, 1000);
      final estimate = CostEstimate.fromJson({'estimate': moneyJson});
      expect(CostEstimate.fromJson(estimate.toJson()).estimate, estimate.estimate);
    });

    test('device code models parse and enforce the approved token', () {
      final issue = DeviceCodeIssue.fromJson({
        'deviceCode': 'dc',
        'userCode': 'ABCD-EFGH',
        'verificationUri': 'https://example.invalid/device',
        'expiresInSeconds': 600,
        'intervalSeconds': 5,
      });
      expect(DeviceCodeIssue.fromJson(issue.toJson()).userCode, 'ABCD-EFGH');

      final pending = DeviceCodeRedeemResult.fromJson({'status': 'pending'});
      expect(pending.status, DeviceCodeStatus.pending);
      expect(
        () => DeviceCodeRedeemResult.fromJson({'status': 'approved'}),
        throwsFormatException,
      );
      expect(
        () => DeviceCodeRedeemResult.fromJson({'status': 'bogus'}),
        throwsFormatException,
      );
      final approved = DeviceCodeRedeemResult.fromJson(
          {'status': 'approved', 'accessToken': 'secret-token'});
      expect(approved.toString(), isNot(contains('secret-token')));
    });
  });
}
