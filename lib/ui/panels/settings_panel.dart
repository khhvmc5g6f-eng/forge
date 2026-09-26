import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/models/model_router.dart';
import '../../core/tools/tool_category.dart';

/// The Settings section: operating mode, granted permission level, routing
/// policy, project root, and provider API keys. Every value here maps
/// directly onto a real [PolicyEngine]/[ModelRouter] input — there is no
/// setting here that only exists cosmetically.
class SettingsPanel extends ConsumerWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(operatingModeProvider);
    final level = ref.watch(permissionLevelProvider);
    final policy = ref.watch(routingPolicyProvider);
    final projectRoot = ref.watch(projectRootProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Project', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(projectRoot),
          subtitle: const Text('Project root'),
        ),
        const Divider(height: 32),
        Text('Operating mode', style: Theme.of(context).textTheme.titleMedium),
        const Text(
          'CHAT (observe only) / ASSIST (propose edits) / AGENT (edit + build/test) / '
          'AUTONOMOUS (full loop up to commit-to-AI-branch) / REVIEW (review only). '
          'Push/PR and production actions always require explicit approval regardless of mode.',
        ),
        DropdownButton<OperatingMode>(
          value: mode,
          items: OperatingMode.values
              .map((m) => DropdownMenuItem(value: m, child: Text(m.name)))
              .toList(),
          onChanged: (v) => ref.read(operatingModeProvider.notifier).state = v!,
        ),
        const Divider(height: 32),
        Text('Granted permission level', style: Theme.of(context).textTheme.titleMedium),
        DropdownButton<PermissionLevel>(
          value: level,
          items: PermissionLevel.values
              .map((l) => DropdownMenuItem(value: l, child: Text('${l.rank}. ${l.name}')))
              .toList(),
          onChanged: (v) => ref.read(permissionLevelProvider.notifier).state = v!,
        ),
        const Divider(height: 32),
        Text('Model routing policy', style: Theme.of(context).textTheme.titleMedium),
        DropdownButton<RoutingPolicy>(
          value: policy,
          items: RoutingPolicy.values
              .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
              .toList(),
          onChanged: (v) => ref.read(routingPolicyProvider.notifier).state = v!,
        ),
        const Divider(height: 32),
        Text('Provider API keys', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        _ApiKeyField(label: 'NVIDIA NIM', secretRef: 'nvidia_nim_api_key'),
        _ApiKeyField(label: 'Anthropic (Claude Final Review)', secretRef: 'anthropic_api_key'),
        _ApiKeyField(label: 'OpenAI', secretRef: 'openai_api_key'),
        const SizedBox(height: 8),
        const Text(
          'Stored via SecretsStore — backed by the macOS Keychain once running on macOS '
          '(see PROVIDERS.md#secrets); this development build uses in-memory storage only.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      ],
    );
  }
}

class _ApiKeyField extends ConsumerStatefulWidget {
  const _ApiKeyField({required this.label, required this.secretRef});
  final String label;
  final String secretRef;

  @override
  ConsumerState<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends ConsumerState<_ApiKeyField> {
  final _controller = TextEditingController();
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              obscureText: true,
              decoration: InputDecoration(labelText: widget.label, isDense: true),
              onChanged: (_) => setState(() => _saved = false),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(_saved ? Icons.check : Icons.save_outlined),
            onPressed: () async {
              await ref.read(secretsStoreProvider).write(widget.secretRef, _controller.text);
              setState(() => _saved = true);
            },
          ),
        ],
      ),
    );
  }
}
