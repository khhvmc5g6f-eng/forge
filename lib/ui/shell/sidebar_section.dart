import 'package:flutter/material.dart';

/// The left-sidebar sections from the brief, plus `controlCentre`: the
/// engine-backed Control Centre (dashboard, circuits, usage, alerts, live
/// flow, network; operational only). Configuration lives in `settings`. Order here is the display
/// order in the [NavigationRail].
enum SidebarSection {
  projects(Icons.folder_outlined, 'Projects'),
  clineHub(Icons.cast_connected_outlined, 'Forge Engine'),
  agents(Icons.smart_toy_outlined, 'Agents'),
  tasks(Icons.checklist_outlined, 'Tasks'),
  git(Icons.merge_type_outlined, 'Git'),
  mcp(Icons.hub_outlined, 'MCP'),
  devices(Icons.phone_iphone_outlined, 'Devices'),
  browser(Icons.public_outlined, 'Browser'),
  terminal(Icons.terminal_outlined, 'Terminal'),
  models(Icons.memory_outlined, 'Models'),
  controlCentre(Icons.hub, 'Control Centre'),
  memory(Icons.psychology_outlined, 'Memory'),
  neuralLab(Icons.science_outlined, 'Neural Lab'),
  diagnostics(Icons.monitor_heart_outlined, 'Diagnostics'),
  settings(Icons.settings_outlined, 'Settings & Connections');

  const SidebarSection(this.icon, this.label);
  final IconData icon;
  final String label;
}
