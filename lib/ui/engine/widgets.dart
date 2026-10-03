import 'package:flutter/material.dart';

import 'format.dart';

/// Small coloured label. Colour is never the only signal: the text names the state.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, this.color, {super.key, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

class CircuitPill extends StatelessWidget {
  const CircuitPill(this.state, {super.key});
  final String state;
  @override
  Widget build(BuildContext context) => StatusPill(prettyState(state).toUpperCase(), circuitColor(state));
}

/// A titled card. [trailing] sits at the right of the title row.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.title, required this.child, this.trailing, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
            ?trailing,
          ]),
          if (subtitle != null)
            Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor))),
          const SizedBox(height: 10),
          child,
        ]),
      ),
    );
  }
}

class Metric extends StatelessWidget {
  const Metric({super.key, required this.label, required this.value, this.sub});
  final String label, value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: t.labelSmall?.copyWith(color: Theme.of(context).hintColor)),
      Text(value, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      if (sub != null) Text(sub!, style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
    ]);
  }
}

class Note extends StatelessWidget {
  const Note(this.text, {super.key, this.icon = Icons.info_outline, this.color});
  final String text;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).hintColor;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: c),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c))),
    ]);
  }
}

/// Horizontal capacity bar. [fraction] null renders an empty bar labelled "no limit set".
class CapacityBar extends StatelessWidget {
  const CapacityBar({super.key, required this.fraction, required this.status});
  final double? fraction;
  final String status;

  @override
  Widget build(BuildContext context) {
    final f = fraction;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: f == null ? 0 : f.clamp(0.0, 1.0),
        minHeight: 8,
        color: capacityColor(status),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }
}

/// Lays children out as a responsive wrap of equal-width columns.
class AdaptiveGrid extends StatelessWidget {
  const AdaptiveGrid({super.key, required this.children, this.minWidth = 320, this.spacing = 12});
  final List<Widget> children;
  final double minWidth, spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / (minWidth + spacing)).floor().clamp(1, 4);
      final w = (c.maxWidth - spacing * (cols - 1)) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    });
  }
}

/// Page scaffold: scrollable, padded, centred and width-limited on big screens.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.onRefresh});
  final List<Widget> children;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 12), child: c)],
    );
    final body = Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1200), child: list));
    return onRefresh == null ? body : RefreshIndicator(onRefresh: onRefresh!, child: body);
  }
}

Future<bool> confirm(BuildContext context, {required String title, required String message, String action = 'Confirm', bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
