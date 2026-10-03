/// Defensive JSON helpers shared by the engine models. A missing or wrongly
/// typed field becomes `null` / an empty collection: the UI then shows
/// "unknown" instead of a made-up value.
double? jNum(Object? v) => v is num ? v.toDouble() : null;
int? jInt(Object? v) => v is num ? v.toInt() : null;
String? jStr(Object? v) => v is String ? v : null;
bool? jBool(Object? v) => v is bool ? v : null;

Map<String, dynamic> jMap(Object? v) => v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

List<T> jList<T>(Object? v, T Function(Map<String, dynamic>) f) =>
    v is List ? v.whereType<Map>().map((m) => f(m.cast<String, dynamic>())).toList(growable: false) : const [];

List<String> jStrList(Object? v) => v is List ? v.whereType<String>().toList(growable: false) : const [];
