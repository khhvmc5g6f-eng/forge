import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cline_hub/hub_root.dart';
import '../panels/agents_panel.dart';
import '../panels/browser_panel.dart';
import '../panels/control_centre_panel.dart';
import '../panels/devices_panel.dart';
import '../panels/diagnostics_panel.dart';
import '../panels/gateway_panel.dart';
import '../panels/git_panel.dart';
import '../panels/mcp_panel.dart';
import '../panels/memory_panel.dart';
import '../panels/models_panel.dart';
import '../panels/neural_lab/neural_lab_panel.dart';
import '../panels/projects_panel.dart';
import '../panels/settings_panel.dart';
import '../panels/tasks_panel.dart';
import '../panels/terminal_panel.dart';
import 'sidebar_section.dart';

final selectedSectionProvider = StateProvider<SidebarSection>((ref) => SidebarSection.tasks);

/// The main application shell: left sidebar (the twelve sections from the
/// brief), a centre body that switches per section, and a persistent bottom
/// Terminal panel — the brief's LEFT SIDEBAR / CENTRE / BOTTOM PANEL layout.
/// (The RIGHT INSPECTOR — files changed/context/tokens/cost — is the next
/// increment once a running Task/Agent supplies that live data; Diagnostics
/// and Git already surface the durable parts of it.)
class ForgeShell extends ConsumerWidget {
  const ForgeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(selectedSectionProvider);
    return Scaffold(
      body: Row(
        children: [
          SingleChildScrollView(
            child: IntrinsicHeight(
              child: NavigationRail(
                selectedIndex: SidebarSection.values.indexOf(section),
                onDestinationSelected: (index) => ref.read(selectedSectionProvider.notifier).state =
                    SidebarSection.values[index],
                // `selected`-only labels keep the rail's height bounded with
                // twelve destinations; each destination's tooltip (from its
                // label) still surfaces the full name on hover.
                labelType: NavigationRailLabelType.selected,
                destinations: SidebarSection.values
                    .map((s) => NavigationRailDestination(
                          icon: Tooltip(message: s.label, child: Icon(s.icon)),
                          label: Text(s.label),
                        ))
                    .toList(),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Text(section.label, style: Theme.of(context).textTheme.titleLarge),
                    ],
                  ),
                ),
                Expanded(child: _bodyFor(section)),
                if (section != SidebarSection.terminal) ...[
                  const Divider(height: 1),
                  const SizedBox(
                    height: 220,
                    child: TerminalPanel(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bodyFor(SidebarSection section) {
    switch (section) {
      case SidebarSection.projects:
        return const ProjectsPanel();
      case SidebarSection.clineHub:
        return const HubRoot(embedded: true);
      case SidebarSection.agents:
        return const AgentsPanel();
      case SidebarSection.tasks:
        return const TasksPanel();
      case SidebarSection.git:
        return const GitPanel();
      case SidebarSection.mcp:
        return const McpPanel();
      case SidebarSection.devices:
        return const DevicesPanel();
      case SidebarSection.browser:
        return const BrowserPanel();
      case SidebarSection.terminal:
        return const TerminalPanel();
      case SidebarSection.models:
        return const ModelsPanel();
      case SidebarSection.controlCentre:
        return const ControlCentrePanel();
      case SidebarSection.gateway:
        return const GatewayPanel();
      case SidebarSection.memory:
        return const MemoryPanel();
      case SidebarSection.neuralLab:
        return const NeuralLabPanel();
      case SidebarSection.diagnostics:
        return const DiagnosticsPanel();
      case SidebarSection.settings:
        return const SettingsPanel();
    }
  }
}
