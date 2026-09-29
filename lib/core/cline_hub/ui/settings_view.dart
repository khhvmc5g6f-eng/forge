import 'package:flutter/material.dart';

import '../state/autonomy.dart';
import '../state/session_controller.dart';
import '../state/voice_controller.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.controller,
    required this.voice,
    required this.onDisconnected,
  });
  final SessionController controller;
  final VoiceController voice;
  final VoidCallback onDisconnected;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, voice]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final providers = controller.providers.where((p) => p.enabled).toList();
        final providerValue = providers.any((p) => p.id == controller.provider)
            ? controller.provider
            : null;
        final models = controller.models[controller.provider] ?? const [];
        final modelValue = models.any((m) => m.id == controller.model)
            ? controller.model
            : null;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Model', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: providerValue,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Provider',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final p in providers)
                  DropdownMenuItem(value: p.id, child: Text(p.name)),
              ],
              onChanged: (v) => controller.select(provider: v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('model-${controller.provider}-${models.length}'),
              initialValue: modelValue,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Model',
                helperText: controller.model != null && modelValue == null
                    ? 'Current: ${controller.model}'
                    : null,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final m in models)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(m.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => controller.select(model: v),
            ),
            const SizedBox(height: 24),
            Text('Autonomy', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<AutonomyLevel>(
              showSelectedIcon: false,
              segments: [
                for (final l in AutonomyLevel.values)
                  ButtonSegment(
                    value: l,
                    label: Text(l.label, style: const TextStyle(fontSize: 12)),
                  ),
              ],
              selected: {controller.autonomy},
              onSelectionChanged: (s) => controller.setAutonomy(s.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                controller.autonomy.description,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 24),
            Text('Voice', style: theme.textTheme.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Read replies aloud'),
              subtitle: const Text(
                'Speaks each completed reply. Never speaks or approves tool actions.',
              ),
              value: controller.speakReplies,
              onChanged: controller.setSpeakReplies,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hands-free conversation'),
              subtitle: const Text(
                'After a reply is read, listen for your next message. Approvals always need a tap.',
              ),
              value: voice.handsFree,
              onChanged: voice.setHandsFree,
            ),
            if (voice.error != null)
              Text(
                voice.error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            const SizedBox(height: 24),
            Text('Connection', style: theme.textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(controller.endpoint?.label ?? 'Not connected'),
              subtitle: Text(controller.status.name),
            ),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () async {
                    await controller.disconnect();
                    onDisconnected();
                  },
                  child: const Text('Disconnect'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () async {
                    await controller.disconnect(forget: true);
                    onDisconnected();
                  },
                  child: const Text('Forget this hub'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
