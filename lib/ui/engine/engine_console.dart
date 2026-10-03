import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';
import 'alerts_page.dart';
import 'circuits_page.dart';
import 'connect_page.dart';
import 'connection_banner.dart';
import 'dashboard_page.dart';
import 'live_flow_page.dart';
import 'network_view.dart';
import 'usage_page.dart';
import 'vault_page.dart';

enum EnginePage {
  dashboard('Dashboard', Icons.dashboard_outlined),
  vault('Vault', Icons.key_outlined),
  circuits('Circuits', Icons.electrical_services_outlined),
  usage('Usage', Icons.data_usage_outlined),
  alerts('Alerts', Icons.notifications_outlined),
  liveFlow('Live Flow', Icons.timeline_outlined),
  network('Network', Icons.hub_outlined),
  connection('Connection', Icons.link);

  const EnginePage(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Which console page is showing; set it to navigate programmatically.
final engineConsolePageProvider = StateProvider<EnginePage>((ref) => EnginePage.dashboard);

/// The Forge Control Centre: dashboard, vault, circuits, usage, alerts, live
/// flow, network and connection, all backed by the engine client. Responsive:
/// rail on tablets and desktops, a scrollable chip bar on phones.
class EngineConsole extends ConsumerWidget {
  const EngineConsole({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(engineConsolePageProvider);
    final conn = ref.watch(engineConnectionProvider);
    final unread = conn.state?.notifications.where((n) => !n.acknowledged).length ?? 0;
    void go(EnginePage p) => ref.read(engineConsolePageProvider.notifier).state = p;

    Widget icon(EnginePage p, {bool selected = false}) {
      final i = Icon(p.icon);
      if (p == EnginePage.alerts) return Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: i);
      return i;
    }

    final content = Column(children: [
      ConnectionBanner(connection: conn, onFix: () => go(EnginePage.connection)),
      Expanded(child: _body(page, go)),
    ]);

    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 700) {
        return Row(children: [
          NavigationRail(
            selectedIndex: page.index,
            extended: c.maxWidth >= 1180,
            labelType: c.maxWidth >= 1180 ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            onDestinationSelected: (i) => go(EnginePage.values[i]),
            destinations: [for (final p in EnginePage.values) NavigationRailDestination(icon: icon(p), label: Text(p.label))],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: content),
        ]);
      }
      // Narrow screens: a scrollable chip bar at the top, so the app's own bottom bar
      // (Engine chat / Control Centre) stays the only bottom navigation.
      return Column(children: [
        ConnectionBanner(connection: conn, onFix: () => go(EnginePage.connection)),
        SizedBox(
          height: 52,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              for (final p in EnginePage.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: p == EnginePage.alerts && unread > 0 ? null : Icon(p.icon, size: 16),
                    label: Text(p == EnginePage.alerts && unread > 0 ? '${p.label} ($unread)' : p.label),
                    selected: p == page,
                    onSelected: (_) => go(p),
                  ),
                ),
            ]),
          ),
        ),
        Expanded(child: _body(page, go)),
      ]);
    });
  }

  Widget _body(EnginePage p, void Function(EnginePage) go) => switch (p) {
        EnginePage.dashboard => DashboardPage(onOpen: (name) => go(EnginePage.values.firstWhere((e) => e.name == name, orElse: () => EnginePage.dashboard))),
        EnginePage.vault => const VaultPage(),
        EnginePage.circuits => const CircuitsPage(),
        EnginePage.usage => const UsagePage(),
        EnginePage.alerts => const AlertsPage(),
        EnginePage.liveFlow => const LiveFlowPage(),
        EnginePage.network => const NetworkPage(),
        EnginePage.connection => const ConnectPage(),
      };
}
