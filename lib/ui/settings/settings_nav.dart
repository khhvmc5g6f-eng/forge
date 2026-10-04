import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sections of the Settings & Connections screen. Each one holds real,
/// persistent configuration; nothing here is a placeholder.
enum SettingsSection {
  connection('Engine connection', Icons.link),
  credentials('Provider credentials', Icons.key_outlined),
  notifications('Notifications', Icons.notifications_outlined),
  localAgent('On-device agent', Icons.tune);

  const SettingsSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The section Settings & Connections shows.
final settingsSectionProvider = StateProvider<SettingsSection>((ref) => SettingsSection.connection);

/// Bumped whenever something asks to open Settings; the app shells listen and
/// switch to their Settings destination. (A counter, not a flag, so asking
/// twice in a row still fires.)
final settingsOpenRequestProvider = StateProvider<int>((ref) => 0);

/// Deep-link into Settings & Connections at [section]. Works from any screen:
/// the Control Centre never edits configuration, it links here.
void openSettings(WidgetRef ref, SettingsSection section) {
  ref.read(settingsSectionProvider.notifier).state = section;
  ref.read(settingsOpenRequestProvider.notifier).state++;
}
