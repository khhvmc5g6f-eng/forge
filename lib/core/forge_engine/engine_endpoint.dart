/// Where a Forge engine (the TypeScript control plane's HTTP surface) lives.
///
/// Pairing strings use the `forge://` scheme and may carry the bearer token:
///   `forge://192.168.1.20:8765?token=abc123&name=Studio%20Mac`
///   `forge://engine.example.com?tls=1&token=...`
/// Plain `http(s)://host:port` and bare `host:port` are accepted too.
class EngineEndpoint {
  const EngineEndpoint({required this.host, required this.port, this.tls = false, this.name});

  static const defaultPort = 8765;

  final String host;
  final int port;
  final bool tls;
  final String? name;

  String get scheme => tls ? 'https' : 'http';
  Uri get baseUri => Uri(scheme: scheme, host: host, port: port);
  String get label => name ?? '$host:$port';

  /// Loopback hosts, where cleartext HTTP never leaves the machine.
  bool get isLoopback =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]' || host.endsWith('.localhost');

  /// RFC1918 / link-local / `.local` hosts (a LAN, not the internet).
  bool get isPrivateNetwork {
    if (isLoopback) return true;
    if (host.endsWith('.local')) return true;
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(host);
    if (m == null) return false;
    final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
    return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 169 && b == 254);
  }

  /// True when the bearer token and any key typed into the app would travel
  /// unencrypted over a network that is not this machine.
  bool get isCleartextOffDevice => !tls && !isLoopback;

  /// Secrets (new provider keys) are only ever sent over TLS or loopback.
  bool get safeForSecrets => tls || isLoopback;

  EngineEndpoint copyWith({String? host, int? port, bool? tls, String? name}) =>
      EngineEndpoint(host: host ?? this.host, port: port ?? this.port, tls: tls ?? this.tls, name: name ?? this.name);

  /// Pairing string for this endpoint (token only when given).
  String toPairingString({String? token}) {
    final q = <String, String>{
      if (tls) 'tls': '1',
      if (name != null && name!.isNotEmpty) 'name': name!,
      if (token != null && token.isNotEmpty) 'token': token,
    };
    return Uri(scheme: 'forge', host: host, port: port == defaultPort && !tls ? null : port, queryParameters: q.isEmpty ? null : q)
        .toString();
  }

  @override
  bool operator ==(Object other) =>
      other is EngineEndpoint && other.host == host && other.port == port && other.tls == tls && other.name == name;

  @override
  int get hashCode => Object.hash(host, port, tls, name);

  @override
  String toString() => 'EngineEndpoint($scheme://$host:$port)';
}

/// Result of parsing what a user typed or pasted.
class ParsedPairing {
  const ParsedPairing(this.endpoint, {this.token});
  final EngineEndpoint endpoint;
  final String? token;
}

/// Parses a `forge://` pairing string, an `http(s)://` URL, or `host[:port]`.
/// Returns null when the text is not a usable address.
ParsedPairing? parsePairing(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty || !_validHost(uri.host)) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'forge' && scheme != 'http' && scheme != 'https') return null;
  final tls = scheme == 'https' || uri.queryParameters['tls'] == '1' || uri.queryParameters['tls'] == 'true';
  final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : EngineEndpoint.defaultPort);
  if (port < 1 || port > 65535) return null;
  final token = uri.queryParameters['token'];
  final name = uri.queryParameters['name'];
  return ParsedPairing(
    EngineEndpoint(
      host: uri.host,
      port: port,
      tls: tls,
      name: (name == null || name.isEmpty) ? null : name,
    ),
    token: (token == null || token.isEmpty) ? null : token,
  );
}

final _ipv4Chars = RegExp(r'^[0-9.]+$');
final _hostLabel = RegExp(r'^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$');

/// Rejects half-typed addresses such as `127.0.0.` or `host..name`.
bool _validHost(String host) {
  if (host.contains(':')) return RegExp(r'^[0-9A-Fa-f:.]+$').hasMatch(host); // IPv6
  if (_ipv4Chars.hasMatch(host)) {
    final parts = host.split('.');
    return parts.length == 4 && parts.every((p) => p.isNotEmpty && p.length <= 3 && int.parse(p) <= 255);
  }
  return host.length <= 253 && host.split('.').every(_hostLabel.hasMatch);
}
