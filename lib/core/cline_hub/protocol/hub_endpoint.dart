/// Where the Cline hub dashboard server (`apps/cline-hub`) is reachable.
///
/// The server authorises WebSocket upgrades by checking the `Host` and
/// `Origin` headers against its public URL and, for non-local binds, a
/// `roomSecret` query parameter. Native sockets can set `Origin`, so the app
/// sends the server's own origin.
class HubEndpoint {
  HubEndpoint._(this.baseUrl, this.roomSecret);

  final Uri baseUrl;
  final String? roomSecret;

  /// Parses user input such as `192.168.1.5:8787`, `http://mac.local:8787` or
  /// `https://hub.example.com`. Returns null when it is not a usable URL.
  static HubEndpoint? tryParse(String input, {String? roomSecret}) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) {
      // Bare host: assume TLS unless it is clearly local.
      text = '${_looksLocal(text) ? 'http' : 'https'}://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    final secret = roomSecret?.trim();
    return HubEndpoint._(
      Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ),
      (secret == null || secret.isEmpty) ? null : secret,
    );
  }

  static bool _looksLocal(String hostish) {
    final host = hostish.split('/').first.split(':').first.toLowerCase();
    return isLocalHost(host);
  }

  /// Loopback, RFC1918, link-local and `.local` mDNS names.
  static bool isLocalHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '10.0.2.2' || h.endsWith('.local')) {
      return true;
    }
    if (h == '::1' || h == '[::1]') return true;
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)\.(\d+)$').firstMatch(h);
    if (m == null) return false;
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    return a == 127 ||
        a == 10 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 169 && b == 254);
  }

  String get origin => Uri(
    scheme: baseUrl.scheme,
    host: baseUrl.host,
    port: baseUrl.hasPort ? baseUrl.port : null,
  ).toString();

  Uri get healthUri => baseUrl.replace(path: '/health');

  Uri get webSocketUri => Uri(
    scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
    host: baseUrl.host,
    port: baseUrl.hasPort ? baseUrl.port : null,
    path: '/browser',
    queryParameters: roomSecret == null ? null : {'roomSecret': roomSecret!},
  );

  /// True when traffic (including the room secret) would cross a network in
  /// clear text to a non-local host. The UI warns about this.
  bool get isInsecureRemote =>
      baseUrl.scheme == 'http' && !isLocalHost(baseUrl.host);

  /// Human-safe label that never includes the secret.
  String get label =>
      baseUrl.hasPort ? '${baseUrl.host}:${baseUrl.port}' : baseUrl.host;
}
