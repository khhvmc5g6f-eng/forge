/// Every Forge Cloud HTTP path lives here so a contract change is a
/// one-line edit.
///
/// Expected contract (implemented in the Forge Azure backend repository; this
/// client is written against it and has not yet been run against the real
/// service):
///
/// * `POST /api/forge-device-code-issue`
///   request `{}`, response
///   `{"deviceCode": str, "userCode": str, "verificationUri": str,
///   "expiresInSeconds": int, "intervalSeconds": int}`
/// * `POST /api/forge-device-code-redeem`
///   request `{"deviceCode": str}`, response
///   `{"status": "pending"|"approved"|"denied"|"expired",
///   "accessToken": str?}` (`accessToken` only when approved)
/// * `GET /api/wallet/balance` (bearer auth)
///   response `{"balance": Money, "updatedAt": ISO-8601?}`
/// * `GET /api/usage/summary` (bearer auth)
///   response `{"monthToDateSpend": Money, "periodStart": ISO-8601?,
///   "recent": [{"id": str, "model": str, "inputTokens": int,
///   "outputTokens": int, "cost": Money, "at": ISO-8601}]}`
/// * `GET /api/models` (bearer auth)
///   response `{"models": [{"id": str, "displayName": str,
///   "deployment": str?, "inputRatePerMillion": Money,
///   "outputRatePerMillion": Money, "contextWindowTokens": int?}]}`
/// * `POST /api/estimate` (bearer auth)
///   request `{"model": str, "inputTokens": int, "outputTokens": int}`,
///   response `{"estimate": Money}`
///
/// `Money` is `{"nanos": "<integer string>", "currency": "GBP"}`: integer
/// nano units (1e-9 of the currency unit) as a string, never a JSON number,
/// so no amount ever passes through a floating-point type.
class ForgeCloudRoutes {
  const ForgeCloudRoutes._();

  static const String deviceCodeIssue = '/api/forge-device-code-issue';
  static const String deviceCodeRedeem = '/api/forge-device-code-redeem';
  static const String walletBalance = '/api/wallet/balance';
  static const String usageSummary = '/api/usage/summary';
  static const String models = '/api/models';
  static const String estimate = '/api/estimate';
}
