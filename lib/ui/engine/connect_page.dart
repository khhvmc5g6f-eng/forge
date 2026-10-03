import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'format.dart';
import 'widgets.dart';

/// Pairing: paste a `forge://` string (or type host:port) and a token. The
/// token lives in the platform secure store and is never shown again.
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key});

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  final _address = TextEditingController();
  final _token = TextEditingController();
  bool _showToken = false;
  String? _error;
  bool _prefilled = false;

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    super.dispose();
  }

  ParsedPairing? get _parsed => parsePairing(_address.text);

  void _apply(String text) {
    final p = parsePairing(text);
    if (p == null) return;
    setState(() {
      _address.text = p.endpoint.baseUri.toString();
      if (p.token != null) _token.text = p.token!;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    final p = parsePairing(text);
    if (p == null) {
      setState(() => _error = 'The clipboard does not hold a forge:// pairing string or an address.');
      return;
    }
    setState(() => _error = null);
    _apply(text);
  }

  Future<void> _connect() async {
    final p = _parsed;
    if (p == null) {
      setState(() => _error = 'Enter an address such as 192.168.1.20:8765, https://forge.example.com or a forge:// pairing string.');
      return;
    }
    setState(() => _error = null);
    final token = _token.text.trim().isEmpty ? p.token : _token.text.trim();
    await ref.read(engineConnectionProvider).configure(p.endpoint, token: token);
    if (mounted) _token.clear();
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(engineConnectionProvider);
    if (!_prefilled && conn.endpoint != null) {
      _prefilled = true;
      _address.text = conn.endpoint!.baseUri.toString();
    }
    final p = _parsed;
    final scheme = Theme.of(context).colorScheme;
    return PageBody(children: [
      Panel(
        title: 'Engine connection',
        subtitle: 'Forge runs its control plane in the TypeScript engine. This app is a client of it.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _StatusRow(conn: conn),
          const SizedBox(height: 14),
          TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Engine address or forge:// pairing string',
              hintText: 'forge://192.168.1.20:8765?token=…',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(tooltip: 'Paste from clipboard', icon: const Icon(Icons.content_paste), onPressed: _paste),
            ),
            onChanged: (v) => setState(() {
              final pp = parsePairing(v);
              if (pp?.token != null && v.contains('token=')) {
                _token.text = pp!.token!;
              }
            }),
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _token,
            obscureText: !_showToken,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: conn.hasToken && _token.text.isEmpty ? 'Bearer token (saved in secure storage; type to replace)' : 'Bearer token',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _showToken ? 'Hide token' : 'Show token',
                icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
            onSubmitted: (_) => _connect(),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: scheme.error))),
          if (p != null) ...[
            const SizedBox(height: 10),
            Note('Will connect to ${p.endpoint.baseUri}${p.token != null ? ' with the token from the pairing string' : ''}.'),
            if (p.endpoint.isCleartextOffDevice) ...[
              const SizedBox(height: 6),
              Note(
                'This address uses unencrypted HTTP to another machine${p.endpoint.isPrivateNetwork ? ' on your local network' : ' over the internet'}. '
                'The bearer token would travel in clear text, and the app will refuse to send new API keys over it. '
                'Prefer an https tunnel (for example Tailscale Serve or a Cloudflare tunnel). '
                'iOS and Android may also block cleartext to LAN addresses.',
                icon: Icons.warning_amber_outlined,
                color: const Color(0xFFE0A100),
              ),
            ],
            if (p.endpoint.isLoopback && (Theme.of(context).platform == TargetPlatform.iOS || Theme.of(context).platform == TargetPlatform.android)) ...[
              const SizedBox(height: 6),
              const Note(
                '127.0.0.1 on a phone is the phone itself. Use your Mac\'s address, or 10.0.2.2 from the Android emulator.',
                icon: Icons.phone_iphone,
              ),
            ],
          ],
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: conn.status == EngineLinkStatus.connecting ? null : _connect,
              icon: const Icon(Icons.link),
              label: Text(conn.endpoint == null ? 'Connect' : 'Save and reconnect'),
            ),
            if (conn.endpoint != null && conn.status != EngineLinkStatus.disconnected)
              OutlinedButton(onPressed: conn.disconnect, child: const Text('Disconnect')),
            if (conn.endpoint != null && conn.status == EngineLinkStatus.disconnected)
              OutlinedButton(onPressed: conn.connect, child: const Text('Reconnect')),
            if (conn.endpoint != null)
              TextButton(
                onPressed: () async {
                  final ok = await confirm(context,
                      title: 'Forget this engine?', message: 'Removes the saved address and deletes the token from secure storage.', action: 'Forget', destructive: true);
                  if (ok) {
                    await conn.forget();
                    _address.clear();
                    _token.clear();
                    _prefilled = false;
                  }
                },
                child: const Text('Forget'),
              ),
          ]),
          if (conn.tokenNotPersisted)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Note(
                'The secure store refused to save the token (an unsigned debug build can do this). It is kept in memory for this session only.',
                icon: Icons.key_off_outlined,
                color: Color(0xFFE0A100),
              ),
            ),
        ]),
      ),
      Panel(
        title: 'How to pair',
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Note('1. Start the engine on your Mac (the Forge control plane, e.g. bun sdk/packages/forge/scripts/forge-gateway.ts).'),
          SizedBox(height: 6),
          Note('2. The gateway listens on loopback only (127.0.0.1:8765). For a phone or another computer, expose it through an https tunnel or a reverse proxy that adds the bearer token.'),
          SizedBox(height: 6),
          Note('3. Paste the forge:// pairing string here, or type the address and token. The token is stored in the Keychain / Keystore, never in plain preferences.'),
          SizedBox(height: 6),
          Note('Engine bearer-token auth is being added to the gateway; until it ships a local engine accepts requests without a token. See docs/ENGINE_API.md.'),
        ]),
      ),
    ]);
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.conn});
  final EngineConnection conn;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (conn.status) {
      EngineLinkStatus.unconfigured => ('NOT PAIRED', const Color(0xFF7A7F87)),
      EngineLinkStatus.connecting => ('CONNECTING', const Color(0xFFE0A100)),
      EngineLinkStatus.connected => (conn.isStale ? 'STALE' : 'CONNECTED', conn.isStale ? const Color(0xFFE0A100) : const Color(0xFF2E9E5B)),
      EngineLinkStatus.reconnecting => ('OFFLINE', const Color(0xFFD64545)),
      EngineLinkStatus.unauthorized => ('UNAUTHORIZED', const Color(0xFFD64545)),
      EngineLinkStatus.disconnected => ('DISCONNECTED', const Color(0xFF7A7F87)),
    };
    final at = conn.lastStateAt;
    return Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      StatusPill(label, color),
      if (conn.endpoint != null) Text(conn.endpoint!.baseUri.toString()),
      if (conn.isConnected) StatusPill(conn.eventsLive ? 'LIVE EVENTS' : 'POLLING ONLY', conn.eventsLive ? const Color(0xFF2E9E5B) : const Color(0xFFE0A100)),
      if (conn.isConnected && conn.capabilitiesKnown) StatusPill(conn.capabilities.readOnly ? 'READ-ONLY ENGINE' : 'ACTIONS ENABLED', const Color(0xFF4A7BD0)),
      if (at != null) Text('updated ${fmtClock(at)}'),
    ]);
  }
}
