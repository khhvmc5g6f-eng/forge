import 'package:flutter/material.dart';

import '../hub_services.dart';
import 'voice_messages.dart';
import 'voice_orb.dart';
import 'voice_ui_controller.dart';

/// Talk to Forge: orb, hold-to-talk, live transcript, interpretation, history, diagnostics.
class VoicePanel extends StatefulWidget {
  const VoicePanel({super.key, required this.services});
  final HubServices services;
  @override
  State<VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends State<VoicePanel> {
  final _typed = TextEditingController();
  final _filter = TextEditingController();
  final _port = TextEditingController(text: '8790');
  bool _showDiag = false;

  VoiceUiController get v => widget.services.voiceUi;

  @override
  void initState() {
    super.initState();
    widget.services.store.loadVoicePort().then((p) {
      if (mounted) _port.text = '$p';
    });
  }

  @override
  void dispose() {
    _typed.dispose();
    _filter.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final e = widget.services.controller.endpoint;
    final port = int.tryParse(_port.text.trim());
    if (e == null || port == null || port < 1 || port > 65535) return;
    await widget.services.store.saveVoicePort(port);
    await v.connect(e, port: port);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: v,
      builder: (context, _) {
        final theme = Theme.of(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: VoiceOrb(state: v.state, level: v.level),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                v.micActive ? 'MICROPHONE ACTIVE' : v.state.label,
                key: const Key('voice-status'),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: v.micActive ? theme.colorScheme.error : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (v.interimNote != null)
              Center(
                child: Text(v.interimNote!, style: theme.textTheme.bodySmall),
              ),
            if (v.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  v.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: 16),
            if (!v.connected) _connectCard(theme) else _talkCard(theme),
            if (v.last != null) _ResultCard(result: v.last!),
            const SizedBox(height: 8),
            _history(theme),
            const SizedBox(height: 8),
            ExpansionTile(
              title: const Text('Diagnostics'),
              initiallyExpanded: _showDiag,
              onExpansionChanged: (x) => _showDiag = x,
              childrenPadding: const EdgeInsets.all(12),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Gateway: ${v.connected ? 'connected' : 'not connected'}'),
                Text('State: ${v.state.name}'),
                Text(
                  'Recogniser: ${v.last?.provider ?? '—'}   latency: ${v.last?.sttMs ?? '—'} ms',
                ),
                Text(
                  'Lowest word confidence: ${v.last?.minConfidence?.toStringAsFixed(2) ?? '—'}',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Mode '),
                    DropdownButton<String>(
                      value: v.mode,
                      items: [
                        for (final m in [
                          'conversation',
                          'command',
                          'continuous',
                          'dictation',
                        ])
                          DropdownMenuItem(value: m, child: Text(m)),
                      ],
                      onChanged: v.connected ? (m) => v.setMode(m!) : null,
                    ),
                    const SizedBox(width: 16),
                    const Text('Speech '),
                    DropdownButton<String>(
                      value: v.verbosity,
                      items: [
                        for (final m in [
                          'silent',
                          'minimal',
                          'normal',
                          'detailed',
                        ])
                          DropdownMenuItem(value: m, child: Text(m)),
                      ],
                      onChanged: v.connected ? (m) => v.setVerbosity(m!) : null,
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _connectCard(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Connect voice', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Speech is recognised on your Mac. Start the voice gateway there (bun scripts/voice-gateway.ts) and enter its port.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: _connect, child: const Text('Connect')),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _talkCard(ThemeData theme) => Column(
    children: [
      Listener(
        onPointerDown: (_) => v.pressToTalk(),
        onPointerUp: (_) => v.releaseToTalk(),
        onPointerCancel: (_) => v.releaseToTalk(),
        child: Semantics(
          button: true,
          label: 'Hold to talk',
          child: Container(
            key: const Key('hold-to-talk'),
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: v.micActive
                  ? theme.colorScheme.error
                  : theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(32),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  v.micActive ? Icons.mic : Icons.mic_none,
                  color: v.micActive
                      ? theme.colorScheme.onError
                      : theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Text(
                  v.micActive ? 'Release to send' : 'Hold to talk',
                  style: TextStyle(
                    color: v.micActive
                        ? theme.colorScheme.onError
                        : theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _typed,
        decoration: InputDecoration(
          hintText: 'or type to Forge',
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: IconButton(
            icon: const Icon(Icons.send),
            onPressed: () {
              v.sendText(_typed.text);
              _typed.clear();
            },
          ),
        ),
        onSubmitted: (t) {
          v.sendText(t);
          _typed.clear();
        },
      ),
    ],
  );

  Widget _history(ThemeData theme) {
    final q = _filter.text.trim().toLowerCase();
    final items = v.history
        .where(
          (h) =>
              q.isEmpty ||
              h.result.heard.toLowerCase().contains(q) ||
              h.result.intent.kind.contains(q),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('History', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        TextField(
          controller: _filter,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: 'Search what you said',
            prefixIcon: Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nothing yet.'),
          ),
        for (final h in items.take(30))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              h.result.heard,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${h.time.hour.toString().padLeft(2, '0')}:${h.time.minute.toString().padLeft(2, '0')} · ${h.result.intent.kind}',
            ),
          ),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});
  final VoiceResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Heard', style: theme.textTheme.labelMedium),
            Text('"${result.heard}"', style: theme.textTheme.bodyLarge),
            for (final c in result.corrections)
              Text('corrected: $c', style: theme.textTheme.bodySmall),
            for (final u in result.uncertain)
              Text(
                'unsure: $u',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            const Divider(height: 24),
            Text(
              'Understood as: ${result.intent.kind}',
              style: theme.textTheme.labelMedium,
            ),
            for (final line in result.intent.interpretation) Text('• $line'),
            if (result.intent.needsConfirmation != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  result.intent.needsConfirmation!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (result.intent.needsClarification != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(result.intent.needsClarification!),
              ),
            if (result.spoken != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Forge: ${result.spoken}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
