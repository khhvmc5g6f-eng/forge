import 'package:meta/meta.dart';

import 'money.dart';

/// Typed JSON models for the Forge Cloud API (see `cloud_routes.dart` for the
/// expected contract). Every model has an explicit `fromJson` / `toJson`.
/// Monetary values use [Money] (integer nano-unit strings); token counts are
/// integers. No field in this file is a `double`.

Map<String, dynamic> _asMap(Object? json, String what) {
  if (json is Map<String, dynamic>) return json;
  throw FormatException('$what must be a JSON object.');
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('"$key" must be a string.');
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('"$key" must be a string when present.');
}

int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('"$key" must be an integer.');
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int) return value;
  throw FormatException('"$key" must be an integer when present.');
}

DateTime _dateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw FormatException('"$key" must be an ISO-8601 timestamp.');
}

DateTime? _optionalDateTime(Map<String, dynamic> json, String key) {
  if (json[key] == null) return null;
  return _dateTime(json, key);
}

List<Map<String, dynamic>> _objectList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) {
    throw FormatException('"$key" must be an array.');
  }
  return value.map((e) => _asMap(e, '"$key" entry')).toList(growable: false);
}

@immutable
class WalletBalance {
  const WalletBalance({required this.balance, this.updatedAt});

  final Money balance;
  final DateTime? updatedAt;

  factory WalletBalance.fromJson(Object? json) {
    final map = _asMap(json, 'WalletBalance');
    return WalletBalance(
      balance: Money.fromJson(map['balance']),
      updatedAt: _optionalDateTime(map, 'updatedAt'),
    );
  }

  Map<String, dynamic> toJson() => {
        'balance': balance.toJson(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
      };
}

@immutable
class UsageRow {
  const UsageRow({
    required this.id,
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
    required this.cost,
    required this.at,
  });

  final String id;
  final String model;
  final int inputTokens;
  final int outputTokens;
  final Money cost;
  final DateTime at;

  factory UsageRow.fromJson(Object? json) {
    final map = _asMap(json, 'UsageRow');
    return UsageRow(
      id: _string(map, 'id'),
      model: _string(map, 'model'),
      inputTokens: _int(map, 'inputTokens'),
      outputTokens: _int(map, 'outputTokens'),
      cost: Money.fromJson(map['cost']),
      at: _dateTime(map, 'at'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'model': model,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'cost': cost.toJson(),
        'at': at.toUtc().toIso8601String(),
      };
}

@immutable
class UsageSummary {
  const UsageSummary({
    required this.monthToDateSpend,
    this.periodStart,
    this.recent = const [],
  });

  final Money monthToDateSpend;
  final DateTime? periodStart;
  final List<UsageRow> recent;

  factory UsageSummary.fromJson(Object? json) {
    final map = _asMap(json, 'UsageSummary');
    return UsageSummary(
      monthToDateSpend: Money.fromJson(map['monthToDateSpend']),
      periodStart: _optionalDateTime(map, 'periodStart'),
      recent: _objectList(map, 'recent')
          .map(UsageRow.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'monthToDateSpend': monthToDateSpend.toJson(),
        if (periodStart != null)
          'periodStart': periodStart!.toUtc().toIso8601String(),
        'recent': recent.map((r) => r.toJson()).toList(),
      };
}

/// One model in the Forge Cloud catalogue, with GBP (or other) rates per
/// million tokens as [Money].
@immutable
class CatalogueModel {
  const CatalogueModel({
    required this.id,
    required this.displayName,
    required this.inputRatePerMillion,
    required this.outputRatePerMillion,
    this.deployment,
    this.contextWindowTokens,
  });

  final String id;
  final String displayName;

  /// Azure deployment name to address, when it differs from [id].
  final String? deployment;
  final Money inputRatePerMillion;
  final Money outputRatePerMillion;
  final int? contextWindowTokens;

  /// Name to pass to the Azure provider for this model.
  String get deploymentName => deployment ?? id;

  factory CatalogueModel.fromJson(Object? json) {
    final map = _asMap(json, 'CatalogueModel');
    return CatalogueModel(
      id: _string(map, 'id'),
      displayName: _string(map, 'displayName'),
      deployment: _optionalString(map, 'deployment'),
      inputRatePerMillion: Money.fromJson(map['inputRatePerMillion']),
      outputRatePerMillion: Money.fromJson(map['outputRatePerMillion']),
      contextWindowTokens: _optionalInt(map, 'contextWindowTokens'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        if (deployment != null) 'deployment': deployment,
        'inputRatePerMillion': inputRatePerMillion.toJson(),
        'outputRatePerMillion': outputRatePerMillion.toJson(),
        if (contextWindowTokens != null)
          'contextWindowTokens': contextWindowTokens,
      };
}

@immutable
class ModelCatalogue {
  const ModelCatalogue({this.models = const []});

  final List<CatalogueModel> models;

  factory ModelCatalogue.fromJson(Object? json) {
    final map = _asMap(json, 'ModelCatalogue');
    return ModelCatalogue(
      models: _objectList(map, 'models')
          .map(CatalogueModel.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'models': models.map((m) => m.toJson()).toList(),
      };
}

@immutable
class CostEstimateRequest {
  const CostEstimateRequest({
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
  });

  final String model;
  final int inputTokens;
  final int outputTokens;

  factory CostEstimateRequest.fromJson(Object? json) {
    final map = _asMap(json, 'CostEstimateRequest');
    return CostEstimateRequest(
      model: _string(map, 'model'),
      inputTokens: _int(map, 'inputTokens'),
      outputTokens: _int(map, 'outputTokens'),
    );
  }

  Map<String, dynamic> toJson() => {
        'model': model,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
      };
}

@immutable
class CostEstimate {
  const CostEstimate({required this.estimate});

  final Money estimate;

  factory CostEstimate.fromJson(Object? json) {
    final map = _asMap(json, 'CostEstimate');
    return CostEstimate(estimate: Money.fromJson(map['estimate']));
  }

  Map<String, dynamic> toJson() => {'estimate': estimate.toJson()};
}

/// Response to the device-code issue call.
@immutable
class DeviceCodeIssue {
  const DeviceCodeIssue({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresInSeconds,
    required this.intervalSeconds,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresInSeconds;
  final int intervalSeconds;

  factory DeviceCodeIssue.fromJson(Object? json) {
    final map = _asMap(json, 'DeviceCodeIssue');
    return DeviceCodeIssue(
      deviceCode: _string(map, 'deviceCode'),
      userCode: _string(map, 'userCode'),
      verificationUri: _string(map, 'verificationUri'),
      expiresInSeconds: _int(map, 'expiresInSeconds'),
      intervalSeconds: _int(map, 'intervalSeconds'),
    );
  }

  Map<String, dynamic> toJson() => {
        'deviceCode': deviceCode,
        'userCode': userCode,
        'verificationUri': verificationUri,
        'expiresInSeconds': expiresInSeconds,
        'intervalSeconds': intervalSeconds,
      };
}

enum DeviceCodeStatus { pending, approved, denied, expired }

/// Response to a device-code redeem call. [accessToken] is set only when
/// [status] is [DeviceCodeStatus.approved]; it is a credential and must go to
/// the SecretsStore, never to logs. [toString] deliberately omits it.
@immutable
class DeviceCodeRedeemResult {
  const DeviceCodeRedeemResult({required this.status, this.accessToken});

  final DeviceCodeStatus status;
  final String? accessToken;

  factory DeviceCodeRedeemResult.fromJson(Object? json) {
    final map = _asMap(json, 'DeviceCodeRedeemResult');
    final raw = _string(map, 'status');
    final status = DeviceCodeStatus.values.firstWhere(
      (s) => s.name == raw,
      orElse: () =>
          throw FormatException('Unknown device code status "$raw".'),
    );
    final token = _optionalString(map, 'accessToken');
    if (status == DeviceCodeStatus.approved &&
        (token == null || token.isEmpty)) {
      throw const FormatException('Approved response is missing accessToken.');
    }
    return DeviceCodeRedeemResult(status: status, accessToken: token);
  }

  Map<String, dynamic> toJson() => {
        'status': status.name,
        if (accessToken != null) 'accessToken': accessToken,
      };

  @override
  String toString() => 'DeviceCodeRedeemResult(${status.name})';
}
