import 'package:meta/meta.dart';

/// A monetary amount held as an integer count of nano units (1e-9 of the
/// currency unit) plus an ISO 4217 currency code.
///
/// Amounts are carried as [BigInt] and serialised as a decimal string, so
/// they never pass through `double`. [fromJson] rejects JSON numbers for the
/// amount on purpose.
@immutable
class Money {
  const Money(this.nanos, this.currency);

  factory Money.zero(String currency) => Money(BigInt.zero, currency);

  static final BigInt _nanosPerUnit = BigInt.from(1000000000);
  static final RegExp _integerPattern = RegExp(r'^-?[0-9]+$');

  final BigInt nanos;
  final String currency;

  factory Money.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Money must be a JSON object.');
    }
    final rawNanos = json['nanos'];
    if (rawNanos is! String || !_integerPattern.hasMatch(rawNanos)) {
      throw const FormatException(
          'Money.nanos must be a string of integer nano units.');
    }
    final rawCurrency = json['currency'];
    if (rawCurrency is! String || rawCurrency.isEmpty) {
      throw const FormatException('Money.currency must be a non-empty string.');
    }
    return Money(BigInt.parse(rawNanos), rawCurrency);
  }

  Map<String, dynamic> toJson() => {
        'nanos': nanos.toString(),
        'currency': currency,
      };

  Money operator +(Money other) {
    _requireSameCurrency(other);
    return Money(nanos + other.nanos, currency);
  }

  bool get isNegative => nanos < BigInt.zero;

  void _requireSameCurrency(Money other) {
    if (other.currency != currency) {
      throw ArgumentError('Currency mismatch: $currency vs ${other.currency}');
    }
  }

  /// Human-readable amount, rounded half away from zero to [decimals] places
  /// using integer arithmetic only, e.g. `£12.35` for GBP. Other currencies
  /// are prefixed with their code, e.g. `EUR 12.35`.
  String format({int decimals = 2}) {
    assert(decimals >= 0 && decimals <= 9);
    final negative = nanos < BigInt.zero;
    final abs = negative ? -nanos : nanos;
    final scale = BigInt.from(10).pow(9 - decimals);
    final half = scale ~/ BigInt.from(2);
    final rounded = (abs + half) ~/ scale;
    final unitScale = BigInt.from(10).pow(decimals);
    final whole = rounded ~/ unitScale;
    final fraction = rounded % unitScale;
    final fractionText =
        decimals == 0 ? '' : '.${fraction.toString().padLeft(decimals, '0')}';
    final prefix = currency == 'GBP' ? '£' : '$currency ';
    return '${negative ? '-' : ''}$prefix$whole$fractionText';
  }

  /// Nano units per whole currency unit; exposed for tests and callers that
  /// convert user-entered whole amounts.
  static BigInt get nanosPerUnit => _nanosPerUnit;

  @override
  bool operator ==(Object other) =>
      other is Money && other.nanos == nanos && other.currency == currency;

  @override
  int get hashCode => Object.hash(nanos, currency);

  @override
  String toString() => 'Money($nanos nanos $currency)';
}
