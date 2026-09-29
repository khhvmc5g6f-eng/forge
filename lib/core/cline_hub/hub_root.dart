import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hub_services.dart';
import 'protocol/hub_client.dart';
import 'ui/chat_view.dart';
import 'ui/connect_screen.dart';
import 'ui/hub_view.dart';
import 'ui/sessions_view.dart';
import 'ui/settings_view.dart';

/// Connect screen until a hub is reachable, then the remote-control workspace
/// (Chat / Sessions / Hub / Settings). Used full-screen on phones and embedded
/// as a section of the desktop shell.
class HubRoot extends ConsumerStatefulWidget {
  const HubRoot({super.key, this.embedded = false});

  /// When embedded in the desktop shell the workspace uses a top tab bar
  /// instead of its own navigation rail / bottom bar.
  final bool embedded;

  @override
  ConsumerState<HubRoot> createState() => _HubRootState();
}

class _HubRootState extends ConsumerState<HubRoot> {
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    final services = ref.read(hubServicesProvider);
    services.boot().whenComplete(() {
      if (mounted) setState(() => _booted = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(hubServicesProvider);
    if (!_booted) return const Center(child: CircularProgressIndicator());
    return ListenableBuilder(
      listenable: services.controller,
      builder: (context, _) {
        final s = services.controller.status;
        final connected =
            s == ConnectionStatus.connected ||
            s == ConnectionStatus.reconnecting;
        if (!connected) {
          final saved = services.savedConnection;
          return ConnectScreen(
            controller: services.controller,
            initialUrl: saved?.url,
            initialSecret: saved?.roomSecret,
          );
        }
        return HubWorkspace(services: services, embedded: widget.embedded);
      },
    );
  }
}

class HubWorkspace extends StatefulWidget {
  const HubWorkspace({
    super.key,
    required this.services,
    this.embedded = false,
  });
  final HubServices services;
  final bool embedded;
  @override
  State<HubWorkspace> createState() => _HubWorkspaceState();
}

class _HubWorkspaceState extends State<HubWorkspace> {
  int _tab = 0;

  static const _destinations = [
    (Icons.chat_bubble_outline, Icons.chat_bubble, 'Chat'),
    (Icons.history, Icons.history, 'Sessions'),
    (Icons.dns_outlined, Icons.dns, 'Hub'),
    (Icons.tune, Icons.tune, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final pages = [
      ChatView(controller: s.controller, voice: s.voice),
      SessionsView(
        controller: s.controller,
        onOpen: () => setState(() => _tab = 0),
      ),
      HubView(controller: s.controller),
      SettingsView(
        controller: s.controller,
        voice: s.voice,
        onDisconnected: () {},
      ),
    ];
    final body = IndexedStack(index: _tab, children: pages);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 720;
        if (wide || widget.embedded) {
          return Row(
            children: [
              NavigationRail(
                selectedIndex: _tab,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: [
                  for (final d in _destinations)
                    NavigationRailDestination(
                      icon: Icon(d.$1),
                      selectedIcon: Icon(d.$2),
                      label: Text(d.$3),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          );
        }
        return Scaffold(
          body: SafeArea(bottom: false, child: body),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              for (final d in _destinations)
                NavigationDestination(
                  icon: Icon(d.$1),
                  selectedIcon: Icon(d.$2),
                  label: d.$3,
                ),
            ],
          ),
        );
      },
    );
  }
}
