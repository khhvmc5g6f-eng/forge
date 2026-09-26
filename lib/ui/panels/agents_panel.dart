import 'package:flutter/material.dart';

import '../../core/agents/agent_role.dart';

/// The Agents section: every specialist role Forge ships, its allowed tool
/// categories, and the task category it defaults to for model routing.
/// Read-only for now — role configuration editing is a Settings extension
/// tracked for a later milestone.
class AgentsPanel extends StatelessWidget {
  const AgentsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final roles = defaultAgentDefinitions.values.toList()
      ..sort((a, b) => a.role.name.compareTo(b.role.name));
    return ListView.builder(
      itemCount: roles.length,
      itemBuilder: (context, index) {
        final def = roles[index];
        return ExpansionTile(
          leading: const Icon(Icons.smart_toy_outlined),
          title: Text(def.role.name),
          subtitle: Text('routes as ${def.defaultTaskCategory.name}'),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def.systemPrompt),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: def.allowedToolCategories
                        .map((c) => Chip(label: Text(c.name)))
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
