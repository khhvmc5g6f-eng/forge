import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/git/git_service.dart';

final gitStatusProvider = FutureProvider.autoDispose<List<ChangedFile>>((ref) async {
  try {
    return await ref.watch(gitServiceProvider).status();
  } on GitException {
    return const [];
  }
});

final gitBranchProvider = FutureProvider.autoDispose<String>((ref) async {
  try {
    return await ref.watch(gitServiceProvider).currentBranch();
  } on GitException {
    return '(not a git repository)';
  }
});

/// The Git section: current branch and changed-files list, backed directly
/// by [GitService] — this is the concrete "AI Changes view" surface (once
/// changes carry agent/task attribution from a running task).
class GitPanel extends ConsumerWidget {
  const GitPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(gitBranchProvider);
    final status = ref.watch(gitStatusProvider);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(gitStatusProvider);
        ref.invalidate(gitBranchProvider);
      },
      child: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.call_split),
            title: const Text('Current branch'),
            subtitle: branch.when(
              data: (b) => Text(b),
              loading: () => const Text('…'),
              error: (e, s) => Text('$e'),
            ),
          ),
          const Divider(),
          status.when(
            data: (files) => files.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Working tree clean.'),
                  )
                : Column(
                    children: files
                        .map((f) => ListTile(
                              dense: true,
                              leading: Text('${f.indexStatus}${f.worktreeStatus}',
                                  style: const TextStyle(fontFamily: 'monospace')),
                              title: Text(f.path),
                            ))
                        .toList(),
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
            error: (e, s) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('$e'),
            ),
          ),
        ],
      ),
    );
  }
}
