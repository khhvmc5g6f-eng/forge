import 'package:flutter/material.dart';

import '../state/session_controller.dart';

class SessionsView extends StatelessWidget {
  const SessionsView({
    super.key,
    required this.controller,
    required this.onOpen,
  });
  final SessionController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final list = [...controller.sessions]
          ..sort((a, b) => (b.updatedAt ?? 0).compareTo(a.updatedAt ?? 0));
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New session'),
              onTap: () {
                controller.newSession();
                onOpen();
              },
            ),
            const Divider(height: 1),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('No sessions on this hub yet.'))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final s = list[i];
                        final selected = s.sessionId == controller.sessionId;
                        return Dismissible(
                          key: ValueKey(s.sessionId),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Theme.of(context).colorScheme.error,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            child: const Icon(
                              Icons.delete,
                              color: Colors.white,
                            ),
                          ),
                          confirmDismiss: (_) async =>
                              await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete session?'),
                                  content: const Text(
                                    'This deletes it on your Mac too.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              ) ??
                              false,
                          onDismissed: (_) =>
                              controller.deleteSession(s.sessionId),
                          child: ListTile(
                            selected: selected,
                            title: Text(
                              s.title?.trim().isNotEmpty == true
                                  ? s.title!
                                  : s.sessionId,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                if (s.status != null) s.status!,
                                if (s.model != null) s.model!,
                              ].join(' · '),
                            ),
                            onTap: () {
                              controller.attachSession(s.sessionId);
                              onOpen();
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
