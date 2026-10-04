import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/forge_engine/forge_engine.dart';
import '../../core/models/model_router.dart';
import '../../core/tools/tool_category.dart';
import '../engine/connect_page.dart';
import '../engine/vault_page.dart';
import '../engine/widgets.dart';
import 'legacy_keys_panel.dart';
import 'settings_nav.dart';

/// Settings & Connections: the only place that configures anything
/// persistent. The Control Centre is operational and links here.
///
/// Every section holds real state: the engine connection (address, token),
/// provider credentials (the engine vault, plus legacy-key migration),
/// notification preference, and (desktop only) the on-device agent's policy
/// inputs. Sections with nothing real to configure do not exist.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, this.showLocalAgent = false, this.showTitle = true});

  /// A heading for shells that do not already show one (the desktop shell does).
  final bool showTitle;

  /// The on-device agent inputs only matter where the desktop shell runs the Dart agent stack.
  final bool showLocalAgent;

  List<SettingsSection> get sections => [
        SettingsSection.connection,
        SettingsSection.credentials,
        SettingsSection.notifications,
        if (showLocalAgent) SettingsSection.localAgent,
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = this.sections;
    var current = ref.watch(settingsSectionProvider);
    if (!sections.contains(current)) current = sections.first;
    final body = _body(current);
    final title = showTitle
        ? Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: Align(alignment: Alignment.centerLeft, child: Text('Settings & Connections', style: Theme.of(context).textTheme.titleLarge)))
        : const SizedBox.shrink();
    return Column(children: [title, Expanded(child: _layout(context, ref, sections, current, body))]);
  }

  Widget _layout(BuildContext context, WidgetRef ref, List<SettingsSection> sections, SettingsSection current, Widget body) {
    void go(SettingsSection s) => ref.read(settingsSectionProvider.notifier).state = s;
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 700) {
        return Row(children: [
          NavigationRail(
            selectedIndex: sections.indexOf(current),
            extended: c.maxWidth >= 1180,
            labelType: c.maxWidth >= 1180 ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            onDestinationSelected: (i) => go(sections[i]),
            destinations: [for (final s in sections) NavigationRailDestination(icon: Icon(s.icon), label: Text(s.label))],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]);
      }
      return Column(children: [
        SizedBox(
          height: 52,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              for (final s in sections)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(avatar: Icon(s.icon, size: 16), label: Text(s.label), selected: s == current, onSelected: (_) => go(s)),
                ),
            ]),
          ),
        ),
        Expanded(child: body),
      ]);
    });
  }

  Widget _body(SettingsSection s) => switch (s) {
        SettingsSection.connection => const ConnectPage(),
        SettingsSection.credentials => const VaultPage(header: [_CredentialPolicy(), LegacyKeysPanel()]),
        SettingsSection.notifications => const NotificationsSection(),
        SettingsSection.localAgent => const LocalAgentSection(),
      };
}

class _CredentialPolicy extends StatelessWidget {
  const _CredentialPolicy();
  @override
  Widget build(BuildContext context) => const Note(
        'Provider API keys are entered only here, into the engine vault. The engine stores them in the OS credential store; this app never keeps a copy and shows them only masked.',
        icon: Icons.shield_outlined,
      );
}

/// Whether critical engine alerts raise OS notifications.
class NotificationsSection extends ConsumerWidget {
  const NotificationsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notify = ref.watch(criticalNotificationsEnabledProvider);
    return PageBody(children: [
      Panel(
        title: 'Critical alerts',
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Notify me about critical alerts'),
          subtitle: const Text('Local notifications on this device, only while the app is running and connected. No push service. Alerts themselves are in Control Centre > Alerts.'),
          value: notify,
          onChanged: (v) {
            ref.read(criticalNotificationsEnabledProvider.notifier).state = v;
            if (v) ref.read(alertNotifierProvider).ensurePermission();
          },
        ),
      ),
    ]);
  }
}

/// Inputs of the on-device [PolicyEngine] and [ModelRouter]. They apply to this
/// device only (they are not engine settings, and are not persisted across restarts).
class LocalAgentSection extends ConsumerWidget {
  const LocalAgentSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(operatingModeProvider);
    final level = ref.watch(permissionLevelProvider);
    final policy = ref.watch(routingPolicyProvider);
    final projectRoot = ref.watch(projectRootProvider);
    final t = Theme.of(context).textTheme;
    return PageBody(children: [
      const Note('These govern the agent stack that runs on this device. They are not engine settings and are not saved across restarts.'),
      Panel(
        title: 'Project',
        child: ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.folder_outlined), title: Text(projectRoot), subtitle: const Text('Project root (change it in Projects)')),
      ),
      Panel(
        title: 'Operating mode',
        subtitle: 'CHAT observe only, ASSIST propose edits, AGENT edit + build/test, AUTONOMOUS full loop up to commit-to-AI-branch, REVIEW review only. Push/PR and production actions always need explicit approval.',
        child: DropdownButton<OperatingMode>(
          value: mode,
          items: [for (final m in OperatingMode.values) DropdownMenuItem(value: m, child: Text(m.name))],
          onChanged: (v) => ref.read(operatingModeProvider.notifier).state = v!,
        ),
      ),
      Panel(
        title: 'Granted permission level',
        child: DropdownButton<PermissionLevel>(
          value: level,
          items: [for (final l in PermissionLevel.values) DropdownMenuItem(value: l, child: Text('${l.rank}. ${l.name}'))],
          onChanged: (v) => ref.read(permissionLevelProvider.notifier).state = v!,
        ),
      ),
      Panel(
        title: 'Model routing policy',
        child: DropdownButton<RoutingPolicy>(
          value: policy,
          items: [for (final p in RoutingPolicy.values) DropdownMenuItem(value: p, child: Text(p.name))],
          onChanged: (v) => ref.read(routingPolicyProvider.notifier).state = v!,
        ),
      ),
      Text('Provider credentials are not set here: see Provider credentials.', style: t.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
    ]);
  }
}
