import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'format.dart';
import 'widgets.dart';

/// Live Flow: what the engine is doing right now, driven only by real events.
/// No event, no motion: an idle engine shows a static page, and the elapsed
/// timers and progress indicators exist only while something is in flight.
class LiveFlowPage extends ConsumerStatefulWidget {
  const LiveFlowPage({super.key});

  @override
  ConsumerState<LiveFlowPage> createState() => _LiveFlowPageState();
}

class _LiveFlowPageState extends ConsumerState<LiveFlowPage> {
  Timer? _tick;

  void _sync(bool active) {
    if (active && _tick == null) {
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    } else if (!active && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(engineConnectionProvider);
    final live = ref.watch(engineLiveProvider);
    final flow = live.flow;
    final active = flow.inFlight;
    final tools = flow.toolsInFlight;
    // Timers are (re)started after the frame so build stays free of side effects.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync(flow.hasActivity));
    final now = live.now;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    if (conn.state == null && conn.status != EngineLinkStatus.connected) {
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Connect to an engine to watch live traffic.')));
    }
    return PageBody(children: [
      Row(children: [
        StatusPill(conn.eventsLive ? 'EVENT STREAM LIVE' : 'EVENT STREAM NOT OPEN', conn.eventsLive ? const Color(0xFF2E9E5B) : const Color(0xFFE0A100)),
        const SizedBox(width: 10),
        Expanded(child: Text(active.isEmpty && tools.isEmpty ? 'Idle: nothing in flight' : '${active.length} request(s) · ${tools.length} tool(s) in flight')),
      ]),
      if (!conn.eventsLive) const Note('Without the event stream this page cannot see requests as they happen. It will not guess.', icon: Icons.sync_problem_outlined),
      if (active.isEmpty && tools.isEmpty)
        const Panel(title: 'In flight', child: Note('Nothing is running. Requests appear here the moment the engine reports them, and disappear when it reports them finished.')),
      for (final r in active) _RequestCard(r: r, now: now, reduceMotion: reduce, state: conn.state),
      for (final t in tools)
        Card(margin: EdgeInsets.zero, child: ListTile(leading: const Icon(Icons.build_outlined), title: Text('Tool: ${t.tool}'), subtitle: Text('running for ${fmtDuration(now.difference(t.startedAt))}${t.agentId == null ? '' : ' · agent ${t.agentId}'}'))),
      Panel(
        title: 'Recently finished',
        child: flow.recent.isEmpty
            ? const Note('No finished requests seen in this session yet.')
            : Column(children: [for (final r in flow.recent.take(15)) _FinishedTile(r: r)]),
      ),
    ]);
  }
}

const _steps = [(FlowStage.uploading, 'Uploading'), (FlowStage.waiting, 'Waiting'), (FlowStage.streaming, 'Streaming'), (FlowStage.complete, 'Complete')];

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.r, required this.now, required this.reduceMotion, required this.state});
  final FlowRequest r;
  final DateTime now;
  final bool reduceMotion;
  final EngineState? state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final current = r.stage == FlowStage.retrying ? FlowStage.uploading : r.stage;
    final idx = _steps.indexWhere((s) => s.$1 == current);
    final ac = state?.active.where((a) => a.requestId == r.requestId).firstOrNull;
    final keyName = r.keyId == null ? null : (state?.keyById(r.keyId!)?.name ?? r.keyId);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r.modelId ?? 'model request', style: t.titleSmall, overflow: TextOverflow.ellipsis)),
            Text(fmtDuration(now.difference(r.startedAt)), style: t.titleSmall),
          ]),
          Text([
            if (r.agentId != null) 'agent ${r.agentId}' else 'unattributed client',
            if (keyName != null) 'key $keyName',
            if (r.providerId != null) r.providerId!,
            if (ac?.tokens != null) '${fmtInt(ac!.tokens)} tok',
            if (ac?.streamTps != null) '${ac!.streamTps!.toStringAsFixed(1)} tok/s',
            if (r.ttftMs != null) 'first token ${fmtMs(r.ttftMs)}',
          ].join(' · '), style: t.bodySmall),
          const SizedBox(height: 10),
          Row(children: [
            for (var i = 0; i < _steps.length; i++) ...[
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_steps[i].$2, style: t.labelSmall?.copyWith(fontWeight: i == idx ? FontWeight.w800 : FontWeight.normal, color: i <= idx ? null : Theme.of(context).hintColor)),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: i < idx
                        ? LinearProgressIndicator(value: 1, minHeight: 5, color: scheme.primary)
                        : i == idx && i != _steps.length - 1
                            ? LinearProgressIndicator(value: reduceMotion ? 0.5 : null, minHeight: 5, color: scheme.primary)
                            : LinearProgressIndicator(value: 0, minHeight: 5, backgroundColor: scheme.surfaceContainerHighest),
                  ),
                ]),
              ),
              if (i < _steps.length - 1) const SizedBox(width: 6),
            ],
          ]),
          if (r.stage == FlowStage.retrying || r.failovers.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final f in r.failovers)
              Note('Failover: ${f.fromKey ?? 'key'} failed${f.kind == null ? '' : ' (${prettyState(f.kind!)}${f.status == null ? '' : ' ${f.status}'})'}${f.toKey == null ? ', no further candidate' : ' → ${f.toKey}'}',
                  icon: Icons.alt_route, color: const Color(0xFFD97A2B)),
            if (r.stage == FlowStage.retrying) const Note('Retrying on the next candidate…', icon: Icons.refresh),
          ],
        ]),
      ),
    );
  }
}

class _FinishedTile extends StatelessWidget {
  const _FinishedTile({required this.r});
  final FlowRequest r;

  @override
  Widget build(BuildContext context) {
    final ok = r.stage == FlowStage.complete;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: ok ? const Color(0xFF2E9E5B) : const Color(0xFFD64545)),
      title: Text(r.modelId ?? r.requestId, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        ok ? 'complete' : 'failed${r.failureReason == null ? '' : ': ${prettyState(r.failureReason!)}'}',
        if (r.latencyMs != null) fmtMs(r.latencyMs),
        if (r.ttftMs != null) 'first token ${fmtMs(r.ttftMs)}',
        if (r.outputTokens != null) '${fmtInt(r.outputTokens)} out',
        if (r.failovers.isNotEmpty) '${r.failovers.length} failover(s)',
      ].join(' · ')),
      trailing: Text(fmtClock(r.endedAt ?? r.startedAt), style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
