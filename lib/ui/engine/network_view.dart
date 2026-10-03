import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'format.dart';
import 'widgets.dart';

Color nodeColor(GraphNode n, ColorScheme scheme) {
  if (n.kind == GraphNodeKind.key || n.kind == GraphNodeKind.provider) {
    return circuitColor(n.state ?? 'unknown');
  }
  return switch (n.kind) {
    GraphNodeKind.agent => scheme.primary,
    GraphNodeKind.tool => scheme.tertiary,
    _ => scheme.secondary,
  };
}

/// The engine as a network: agents and tools, models, keys, providers.
/// Structure is dim and static. An edge lights up, with a pulse travelling
/// along it, only for [EngineGraph.pulseWindow] after a real engine event
/// crossed it. The ticker runs only while at least one edge is lit.
class EngineNetworkView extends ConsumerStatefulWidget {
  const EngineNetworkView({super.key});

  @override
  ConsumerState<EngineNetworkView> createState() => _EngineNetworkViewState();
}

class _EngineNetworkViewState extends ConsumerState<EngineNetworkView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      final live = ref.read(engineLiveProvider);
      if (live.graph.activeEdges(live.now).isEmpty) {
        _ticker.stop();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(engineConnectionProvider);
    final live = ref.watch(engineLiveProvider);
    final graph = live.graph;
    final now = live.now;
    final lit = graph.activeEdges(now);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (lit.isNotEmpty && !_ticker.isActive && !reduce) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_ticker.isActive) _ticker.start();
      });
    }
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected == null ? null : graph.nodes[_selected];

    Widget body;
    if (graph.nodes.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            conn.state == null ? 'Connect to an engine to see its network.' : 'The engine has no providers or keys yet, and has reported no traffic.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      body = LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, math.max(260, c.maxHeight.isFinite ? c.maxHeight : 420));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            GraphNode? hit;
            var best = 28.0;
            for (final n in graph.nodes.values) {
              final p = _pos(n, size);
              final dist = (p - d.localPosition).distance;
              if (dist < best) {
                best = dist;
                hit = n;
              }
            }
            setState(() => _selected = hit?.id);
          },
          child: CustomPaint(
            size: size,
            painter: _NetworkPainter(graph: graph, now: now, scheme: scheme, selected: _selected, textColor: Theme.of(context).textTheme.bodySmall?.color ?? scheme.onSurface, animate: !reduce, revision: graph.revision),
          ),
        );
      });
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusPill(conn.eventsLive ? 'LIVE EVENTS' : 'NO EVENT STREAM', conn.eventsLive ? const Color(0xFF2E9E5B) : const Color(0xFFE0A100)),
          Text(lit.isEmpty ? 'Idle: edges light up only when the engine reports traffic' : '${lit.length} active edge(s)', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      Expanded(child: body),
      if (selected != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('${selected.kind.name} · ${selected.label}${selected.state == null ? '' : ' · ${prettyState(selected.state!)}'}${selected.detail == null ? '' : ' · ${selected.detail}'}'
              '${selected.lastEventAt == null ? ' · no events seen' : ' · last event ${fmtAgo(selected.lastEventAt, now)}'}'),
        ),
      const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 8), child: _Legend()),
    ]);
  }

  static Offset _pos(GraphNode n, Size s) => Offset(24 + n.x * (s.width - 48), 20 + n.y * (s.height - 40));
}

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme.labelSmall;
    return Wrap(spacing: 14, runSpacing: 2, children: [
      Text('Columns: agents & tools → models → keys → providers', style: t),
      Text('Node colour = circuit state', style: t),
      Text('Dim line = configured, bright pulse = real event', style: t),
      Text('Red pulse = failure', style: t),
    ]);
  }
}

class _NetworkPainter extends CustomPainter {
  _NetworkPainter({required this.graph, required this.now, required this.scheme, required this.selected, required this.textColor, required this.animate, required this.revision});
  final EngineGraph graph;
  final DateTime now;
  final ColorScheme scheme;
  final String? selected;
  final Color textColor;
  final bool animate;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    Offset pos(GraphNode n) => _EngineNetworkViewState._pos(n, size);
    final dim = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = 1;
    for (final e in graph.edges.values) {
      final a = graph.nodes[e.from], b = graph.nodes[e.to];
      if (a == null || b == null) continue;
      final pa = pos(a), pb = pos(b);
      final p = graph.pulseProgress(e, now);
      if (p == null) {
        // Configured structure and edges that carried traffic earlier stay faintly visible.
        canvas.drawLine(pa, pb, dim..color = scheme.outlineVariant.withValues(alpha: e.structural ? 0.7 : 0.4));
        continue;
      }
      final color = e.lastPulseFailed ? const Color(0xFFD64545) : scheme.primary;
      final fade = 1 - p;
      canvas.drawLine(pa, pb, Paint()
        ..color = color.withValues(alpha: 0.25 + 0.6 * fade)
        ..strokeWidth = 2.5);
      if (animate) {
        final dot = Offset.lerp(pa, pb, Curves.easeInOut.transform((p * 2.2).clamp(0.0, 1.0)))!;
        canvas.drawCircle(dot, 6, Paint()..color = color.withValues(alpha: 0.35 * fade + 0.1));
        canvas.drawCircle(dot, 3.5, Paint()..color = color);
      }
    }
    for (final n in graph.nodes.values) {
      final p = pos(n);
      final c = nodeColor(n, scheme);
      final r = n.kind == GraphNodeKind.provider ? 11.0 : (n.kind == GraphNodeKind.key ? 8.0 : 9.0);
      final recent = n.lastEventAt != null && now.difference(n.lastEventAt!) < EngineGraph.pulseWindow;
      if (recent) canvas.drawCircle(p, r + 5, Paint()..color = c.withValues(alpha: 0.25));
      if (n.kind == GraphNodeKind.tool) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: r * 2, height: r * 2), const Radius.circular(3)), Paint()..color = c);
      } else {
        canvas.drawCircle(p, r, Paint()..color = c);
      }
      if (n.id == selected) {
        canvas.drawCircle(p, r + 4, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = textColor);
      }
      final tp = TextPainter(
        text: TextSpan(text: n.label, style: TextStyle(color: textColor, fontSize: 11)),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(40, size.width / 5.2));
      final below = n.y < 0.98;
      final off = Offset(math.min(math.max(2, p.dx - tp.width / 2), size.width - tp.width - 2), p.dy + (below ? r + 2 : -r - tp.height - 2));
      tp.paint(canvas, off);
    }
  }

  @override
  bool shouldRepaint(_NetworkPainter old) => old.now != now || old.revision != revision || old.selected != selected || old.scheme != scheme;
}

/// Standalone page wrapper (the Neural Lab hosts [EngineNetworkView] directly).
class NetworkPage extends StatelessWidget {
  const NetworkPage({super.key});
  @override
  Widget build(BuildContext context) => const EngineNetworkView();
}
