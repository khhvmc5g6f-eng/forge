import 'package:flutter/material.dart';

/// The left-sidebar sections from the brief, plus `controlCentre` added by
/// the Multi-Provider Control Plane extension. Order here is the display
/// order in the [NavigationRail].
enum SidebarSection {
  projects(Icons.folder_outlined, 'Projects'),
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
  diagnostics(Icons.monitor_heart_outlined, 'Diagnostics'),
  settings(Icons.settings_outlined, 'Settings');

  const SidebarSection(this.icon, this.label);
  final IconData icon;
  final String label;
}
