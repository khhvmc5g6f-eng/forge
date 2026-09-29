import 'package:flutter/material.dart';

import '../state/session_controller.dart';

class HubView extends StatelessWidget {
  const HubView({super.key, required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = controller.hubState;
        final theme = Theme.of(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  s.connected ? Icons.check_circle : Icons.error_outline,
                  color: s.connected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                title: Text(s.connected ? 'Hub running' : 'Hub not connected'),
                subtitle: Text(
                  [
                    if (s.coreVersion != null) 'core ${s.coreVersion}',
                    if (s.hubUptime != null) 'up ${s.hubUptime}',
                    'via ${controller.endpoint?.label ?? '—'}',
                  ].join(' · '),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Connected clients (${s.clients.length})',
              style: theme.textTheme.titleSmall,
            ),
            for (final c in s.clients)
              ListTile(
                dense: true,
                leading: const Icon(Icons.devices),
                title: Text(c.displayName ?? c.clientType),
                subtitle: Text(c.clientType),
              ),
            const SizedBox(height: 8),
            Text(
              'Active sessions (${s.sessions.length})',
              style: theme.textTheme.titleSmall,
            ),
            for (final x in s.sessions)
              ListTile(
                dense: true,
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(
                  x.title ?? x.sessionId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  [
                    if (x.status != null) x.status!,
                    if (x.model != null) x.model!,
                  ].join(' · '),
                ),
              ),
            const SizedBox(height: 8),
            Text('Recent events', style: theme.textTheme.titleSmall),
            if (s.events.isEmpty)
              const Padding(padding: EdgeInsets.all(8), child: Text('None')),
            for (final e in s.events.reversed.take(20))
              ListTile(
                dense: true,
                leading: Icon(switch (e.severity) {
                  'error' => Icons.error_outline,
                  'warn' => Icons.warning_amber,
                  'success' => Icons.check_circle_outline,
                  _ => Icons.info_outline,
                }),
                title: Text(e.title),
                subtitle: Text(e.body),
              ),
          ],
        );
      },
    );
  }
}
