import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'actions.dart';
import 'format.dart';
import 'widgets.dart';

/// Notification centre + runaway guard. Local OS notifications for critical
/// alerts are raised by [EngineAlertBridge] while the app is connected.
class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(engineConnectionProvider);
    final s = conn.state;
    final notify = ref.watch(criticalNotificationsEnabledProvider);
    if (s == null) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Connect to an engine to see its alerts.')));
    final ackBlocked = actionBlockedReason(conn, 'alert.ack');
    final guardBlocked = actionBlockedReason(conn, 'guard.resume');
    final alerts = [...s.notifications]..sort((a, b) => b.ts.compareTo(a.ts));
    final unread = alerts.where((a) => !a.acknowledged).length;
    final now = DateTime.fromMillisecondsSinceEpoch(s.now);
    return PageBody(onRefresh: conn.refresh, children: [
      Panel(
        title: 'Notifications',
        subtitle: '$unread unacknowledged of ${alerts.length}',
        trailing: Tooltip(
          message: ackBlocked ?? 'Acknowledge every alert',
          child: TextButton(onPressed: ackBlocked != null || unread == 0 ? null : () => runEngineAction(context, conn, (c) => c.acknowledge(all: true)), child: const Text('Acknowledge all')),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notify me about critical alerts'),
            subtitle: const Text('Local notifications on this device, only while the app is running and connected. No push service.'),
            value: notify,
            onChanged: (v) {
              ref.read(criticalNotificationsEnabledProvider.notifier).state = v;
              if (v) ref.read(alertNotifierProvider).ensurePermission();
            },
          ),
          if (ackBlocked != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Note(ackBlocked, icon: Icons.lock_outline)),
          if (alerts.isEmpty) const Note('No alerts.', icon: Icons.check_circle_outline, color: Color(0xFF2E9E5B)),
          for (final a in alerts)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(severityIcon(a.severity), color: severityColor(a.severity)),
              title: Text(a.title, style: TextStyle(fontWeight: a.acknowledged ? FontWeight.normal : FontWeight.w700)),
              subtitle: Text('${a.message}\n${a.severity} · ${fmtAgo(DateTime.fromMillisecondsSinceEpoch(a.ts), now)}${a.repeats > 0 ? ' · seen ${a.repeats + 1}×' : ''}'),
              isThreeLine: true,
              trailing: a.acknowledged
                  ? const Icon(Icons.done, size: 18)
                  : Tooltip(message: ackBlocked ?? 'Acknowledge', child: IconButton(icon: const Icon(Icons.check), onPressed: ackBlocked != null ? null : () => runEngineAction(context, conn, (c) => c.acknowledge(id: a.id)))),
            ),
        ]),
      ),
      Panel(
        title: 'Runaway guard',
        subtitle: 'Burn rate, duplicate requests, loops and retry storms, per scope.',
        child: s.guard.isEmpty
            ? const Note('No guard scopes are active.')
            : Column(children: [for (final g in s.guard) _GuardTile(g: g, conn: conn, blocked: guardBlocked)]),
      ),
    ]);
  }
}

class _GuardTile extends StatelessWidget {
  const _GuardTile({required this.g, required this.conn, required this.blocked});
  final EngineGuardScope g;
  final EngineConnection conn;
  final String? blocked;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = g.paused ? severityColor('critical') : (g.level == 'none' ? const Color(0xFF2E9E5B) : severityColor('warning'));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(g.scope, style: t.titleSmall, overflow: TextOverflow.ellipsis)),
          StatusPill(g.paused ? 'PAUSED' : prettyState(g.level).toUpperCase(), color),
        ]),
        Text(
          'Burn ${fmtInt(g.current.tokensPerMin)} tok/min · ${g.current.callsPerMin?.toStringAsFixed(1) ?? unknownText} calls/min'
          '${g.tokensIncreasePct == null ? ' · no baseline yet' : ' · ${g.tokensIncreasePct!.toStringAsFixed(0)}% above baseline'}',
          style: t.bodySmall,
        ),
        if (g.duplicateRequests > 0) Text('${g.duplicateRequests} duplicate request(s), ~${fmtInt(g.resentTokensEstimated)} tokens resent (estimated)', style: t.bodySmall),
        for (final sig in g.signals.reversed.take(3)) Text('${prettyState(sig.kind)}: ${sig.detail}', style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
        if (g.needsAttention)
          Tooltip(
            message: blocked ?? 'Clear the guard level and resume',
            child: TextButton.icon(onPressed: blocked != null ? null : () => runEngineAction(context, conn, (c) => c.resumeGuard(g.scope)), icon: const Icon(Icons.play_arrow, size: 16), label: const Text('Resume')),
          ),
      ]),
    );
  }
}
