import 'package:flutter/material.dart';

import '../../core/forge_engine/engine_connection.dart';
import 'format.dart';

/// One line that tells the truth about the link: what state it is in and how
/// old the data on screen is. Hidden only when everything is live.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.connection, this.onFix});
  final EngineConnection connection;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final c = connection;
    final scheme = Theme.of(context).colorScheme;
    final at = c.lastStateAt;
    String? text;
    var color = scheme.errorContainer;
    var onColor = scheme.onErrorContainer;
    IconData icon = Icons.cloud_off_outlined;
    switch (c.status) {
      case EngineLinkStatus.unconfigured:
        text = 'No engine connected. Pair with a Forge engine to see live data.';
        color = scheme.surfaceContainerHighest;
        onColor = scheme.onSurface;
        icon = Icons.link_off;
      case EngineLinkStatus.connecting:
        text = 'Connecting to ${c.endpoint?.label ?? 'engine'}…';
        color = scheme.surfaceContainerHighest;
        onColor = scheme.onSurface;
        icon = Icons.sync;
      case EngineLinkStatus.connected:
        if (c.isStale) {
          text = 'Data is stale (last update ${at == null ? 'unknown' : fmtClock(at)}).';
          icon = Icons.history_toggle_off;
        } else if (!c.eventsLive) {
          text = 'Connected, polling only: the live event stream is not open, so Live Flow may lag.';
          color = scheme.tertiaryContainer;
          onColor = scheme.onTertiaryContainer;
          icon = Icons.sync_problem_outlined;
        } else if (c.missedEvents > 0) {
          text = 'Connected. ${c.missedEvents} event(s) were missed while the stream was down.';
          color = scheme.tertiaryContainer;
          onColor = scheme.onTertiaryContainer;
          icon = Icons.info_outline;
        }
      case EngineLinkStatus.reconnecting:
        text = 'Engine ${c.endpoint?.label ?? ''} is not answering (${c.error ?? 'no reason given'}). '
            'Retrying with backoff (attempt ${c.retryAttempt}).'
            '${c.state == null ? '' : ' Showing data from ${at == null ? 'an earlier poll' : fmtClock(at)}, which may be out of date.'}';
        icon = Icons.cloud_off_outlined;
      case EngineLinkStatus.unauthorized:
        text = '${c.error ?? 'The engine rejected the token.'} Open Connection to re-pair.';
        icon = Icons.lock_outline;
      case EngineLinkStatus.disconnected:
        text = 'Disconnected. Nothing is being updated.';
        color = scheme.surfaceContainerHighest;
        onColor = scheme.onSurface;
        icon = Icons.link_off;
    }
    if (text == null) return const SizedBox.shrink();
    return Material(
      color: color,
      child: InkWell(
        onTap: onFix,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [
            Icon(icon, size: 18, color: onColor),
            const SizedBox(width: 8),
            Expanded(child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: onColor, fontSize: 13))),
          ]),
        ),
      ),
    );
  }
}
