import 'package:flutter/material.dart';

import '../protocol/hub_client.dart';
import '../protocol/hub_endpoint.dart';
import '../state/session_controller.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    required this.controller,
    this.initialUrl,
    this.initialSecret,
  });
  final SessionController controller;
  final String? initialUrl;
  final String? initialSecret;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initialUrl ?? '',
  );
  late final TextEditingController _secret = TextEditingController(
    text: widget.initialSecret ?? '',
  );
  bool _busy = false;
  bool _showSecret = false;
  String? _error;

  HubEndpoint? get _endpoint =>
      HubEndpoint.tryParse(_url.text, roomSecret: _secret.text);

  Future<void> _connect() async {
    final e = _endpoint;
    if (e == null) {
      setState(
        () => _error =
            'Enter a valid address, e.g. 192.168.1.20:8787 or https://hub.example.com',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final probe = await HubClient.probe(e);
    if (probe != null) {
      setState(() {
        _busy = false;
        _error = 'Cannot reach ${e.label}: $probe';
      });
      return;
    }
    await widget.controller.connect(e);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = widget.controller.isConnected ? null : widget.controller.banner;
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = _endpoint;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Icon(
                  Icons.terminal_rounded,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text('Connect to Forge', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'This app is a remote control. The Forge engine runs on your Mac; start its hub there with `bun run start` in apps/cline-hub.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Hub address',
                    hintText: '192.168.1.20:8787',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _secret,
                  obscureText: !_showSecret,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Room secret',
                    helperText:
                        'The hub\'s ROOM_SECRET (required when it listens on your network)',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: _showSecret ? 'Hide' : 'Show',
                      icon: Icon(
                        _showSecret ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _showSecret = !_showSecret),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (e != null && e.isInsecureRemote) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'This address is not on your local network and is not using https. Your room secret and everything the agent sees would cross the internet unencrypted. Use an https/wss tunnel (for example Tailscale Serve or a Cloudflare tunnel).',
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: (_busy || e == null) ? null : _connect,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
