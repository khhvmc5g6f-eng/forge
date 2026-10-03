import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_gateway/gateway_client.dart';
import '../../core/forge_gateway/gateway_models.dart';

final gatewayClientProvider = ChangeNotifierProvider<GatewayClient>((ref) => GatewayClient());

/// Live view of the Forge control-plane gateway: providers, API keys (masked
/// only), circuit state, in-flight calls and the real event feed. Shows
/// "unknown" wherever the gateway reports nothing.
class GatewayPanel extends ConsumerStatefulWidget {
  const GatewayPanel({super.key});

  @override
  ConsumerState<GatewayPanel> createState() => _GatewayPanelState();
}

class _GatewayPanelState extends ConsumerState<GatewayPanel> {
  final _url = TextEditingController(text: 'http://127.0.0.1:8765');

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(gatewayClientProvider);
    final connected = g.status == GatewayStatus.connected;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _url,
                decoration: const InputDecoration(labelText: 'Gateway address', isDense: true),
                onSubmitted: (v) => g.connect(v),
              ),
            ),
            const SizedBox(width: 8),
            connected
                ? OutlinedButton(onPressed: g.disconnect, child: const Text('Disconnect'))
                : FilledButton(
                    onPressed: g.status == GatewayStatus.connecting ? null : () => g.connect(_url.text),
                    child: const Text('Connect')),
          ]),
          const SizedBox(height: 4),
          Text(_statusText(g), style: TextStyle(color: g.status == GatewayStatus.error ? Colors.red : null)),
          const SizedBox(height: 8),
          if (g.state == null)
            const Expanded(
                child: Center(
                    child: Text('Not connected. Start the gateway:  bun sdk/packages/forge/scripts/forge-gateway.ts')))
          else
            Expanded(child: _body(context, g)),
        ],
      ),
    );
  }

  String _statusText(GatewayClient g) => switch (g.status) {
        GatewayStatus.disconnected => 'Disconnected',
        GatewayStatus.connecting => 'Connecting…',
        GatewayStatus.connected => 'Connected · ${g.state?.keys.length ?? 0} keys · ${g.state?.openCircuits ?? 0} non-closed circuits',
        GatewayStatus.error => g.error ?? 'Error',
      };

  Widget _body(BuildContext context, GatewayClient g) {
    final s = g.state!;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        flex: 3,
        child: ListView(children: [
          Text('Keys', style: Theme.of(context).textTheme.titleSmall),
          if (s.keys.isEmpty) const ListTile(title: Text('No keys registered in the gateway vault')),
          for (final k in s.keys) _keyTile(k),
          const SizedBox(height: 12),
          Text('In flight (${s.active.length})', style: Theme.of(context).textTheme.titleSmall),
          for (final a in s.active)
            ListTile(
              dense: true,
              title: Text(a.id),
              subtitle: Text('${a.tokens ?? "?"} tokens · ${a.streamTps?.toStringAsFixed(1) ?? "?"} tok/s'),
            ),
        ]),
      ),
      const VerticalDivider(width: 16),
      Expanded(
        flex: 2,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Events', style: Theme.of(context).textTheme.titleSmall),
          Expanded(
            child: ListView(reverse: true, children: [
              for (final e in g.events.reversed)
                Text('${e.seq}  ${e.type}', style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _keyTile(GatewayKey k) {
    final health = k.healthScore == null ? 'health unknown' : 'health ${k.healthScore!.toStringAsFixed(0)}';
    final lat = k.p50LatencyMs == null ? 'latency unknown' : 'p50 ${k.p50LatencyMs!.toStringAsFixed(0)} ms';
    return ListTile(
      dense: true,
      leading: Icon(Icons.vpn_key_outlined, color: k.enabled ? null : Colors.grey),
      title: Text('${k.name}  ·  ${k.providerId}  ${k.masked ?? ""}'),
      subtitle: Text('circuit ${k.circuitState ?? "unknown"} · $health · $lat · ${k.requests15m ?? "?"} req/15m'),
    );
  }
}
