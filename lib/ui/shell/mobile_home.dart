import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cline_hub/hub_root.dart';
import '../engine/engine_console.dart';

/// Which top-level destination the phone/tablet shell shows.
enum MobileTab {
  chat('Engine chat', Icons.chat_bubble_outline),
  control('Control Centre', Icons.hub_outlined);

  const MobileTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

final mobileTabProvider = StateProvider<MobileTab>((ref) => MobileTab.chat);

/// iPhone / iPad / Android shell: the Cline-engine chat workspace and the
/// engine-backed Control Centre, both clients of the TypeScript engine.
/// Phones get a bottom bar, tablets (>= 840 dp) a rail. Both tabs stay mounted
/// so switching never drops a chat or a connection.
class MobileHome extends ConsumerWidget {
  const MobileHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(mobileTabProvider);
    void go(MobileTab t) => ref.read(mobileTabProvider.notifier).state = t;
    final body = IndexedStack(index: tab.index, children: const [HubRoot(), EngineConsole()]);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 840) {
        return Scaffold(
          body: SafeArea(
            child: Row(children: [
              NavigationRail(
                selectedIndex: tab.index,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => go(MobileTab.values[i]),
                destinations: [for (final t in MobileTab.values) NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label))],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ]),
          ),
        );
      }
      return Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab.index,
          onDestinationSelected: (i) => go(MobileTab.values[i]),
          destinations: [for (final t in MobileTab.values) NavigationDestination(icon: Icon(t.icon), label: t.label)],
        ),
      );
    });
  }
}
