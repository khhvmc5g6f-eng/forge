import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/forge_providers.dart';
import '../../core/context/repo_index.dart';
import '../../core/project/project_manager.dart';

final recentProjectsProvider = FutureProvider.autoDispose((ref) async {
  return ref.watch(projectManagerProvider).listRecent();
});

/// The Projects section: open a folder, switch between recently-opened
/// projects, and trigger/inspect this project's Repository Index. Each
/// recent project is genuinely isolated — switching sets
/// [projectRootProvider], and every other provider (`gitServiceProvider`,
/// `taskManagerProvider`, `memoryStoreProvider`, the `ToolGateway`) is
/// derived from it, so a switch tears down and rebuilds all of them for the
/// new root automatically.
class ProjectsPanel extends ConsumerStatefulWidget {
  const ProjectsPanel({super.key});

  @override
  ConsumerState<ProjectsPanel> createState() => _ProjectsPanelState();
}

class _ProjectsPanelState extends ConsumerState<ProjectsPanel> {
  final _pathController = TextEditingController();
  final _searchController = TextEditingController();
  bool _indexing = false;
  String? _openError;
  List<RepoSearchResult>? _searchResults;

  @override
  Widget build(BuildContext context) {
    final currentRoot = ref.watch(projectRootProvider);
    final recentAsync = ref.watch(recentProjectsProvider);
    final index = ref.watch(repoIndexProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Current project', style: Theme.of(context).textTheme.titleMedium),
        ListTile(leading: const Icon(Icons.folder), title: Text(currentRoot)),
        const Divider(height: 32),
        Text('Open a folder', style: Theme.of(context).textTheme.titleMedium),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pathController,
                decoration: const InputDecoration(
                  hintText: 'Absolute path to a project directory',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _openPath, child: const Text('Open')),
          ],
        ),
        if (_openError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_openError!, style: const TextStyle(color: Colors.red)),
          ),
        const Text(
          'Clone GitHub Repository is not yet implemented in this build — clone with your '
          'usual `git clone` first, then open the resulting folder here.',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
        const Divider(height: 32),
        Text('Recent projects', style: Theme.of(context).textTheme.titleMedium),
        recentAsync.when(
          data: (projects) => projects.isEmpty
              ? const Padding(padding: EdgeInsets.all(8), child: Text('No recent projects yet.'))
              : Column(
                  children: projects
                      .map((p) => ListTile(
                            leading: const Icon(Icons.history),
                            title: Text(p.displayName),
                            subtitle: Text(p.path),
                            trailing: p.path == currentRoot
                                ? const Chip(label: Text('current'))
                                : TextButton(
                                    onPressed: () => _switchTo(p.path),
                                    child: const Text('Open'),
                                  ),
                          ))
                      .toList(),
                ),
          loading: () => const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
          error: (e, s) => Padding(padding: const EdgeInsets.all(8), child: Text('$e')),
        ),
        const Divider(height: 32),
        Text('Repository index', style: Theme.of(context).textTheme.titleMedium),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _indexing ? null : _buildIndex,
              icon: _indexing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.travel_explore),
              label: Text(index == null ? 'Index now' : 'Re-index'),
            ),
            const SizedBox(width: 12),
            if (index != null)
              Text('${index.fileCount} files · ${index.symbolCount} symbols · '
                  'built ${index.builtAt.toLocal()}'),
          ],
        ),
        if (index != null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search symbols/files (e.g. "PolicyEngine")',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (query) {
              setState(() => _searchResults = RepoSearch(index).search(query));
            },
          ),
          const SizedBox(height: 8),
          if (_searchResults != null)
            ..._searchResults!.map((r) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.code),
                  title: Text(r.matchedSymbol?.name ?? r.file),
                  subtitle: Text('${r.file}${r.matchedSymbol != null ? ':${r.matchedSymbol!.line}' : ''}'),
                  trailing: Text(r.score.toStringAsFixed(0)),
                )),
        ],
      ],
    );
  }

  Future<void> _openPath() async {
    setState(() => _openError = null);
    try {
      final opened = await ref.read(projectManagerProvider).open(_pathController.text.trim());
      _switchTo(opened);
    } on ProjectNotFoundException catch (e) {
      setState(() => _openError = e.toString());
    }
  }

  void _switchTo(String path) {
    ref.read(projectRootProvider.notifier).state = path;
    ref.read(repoIndexProvider.notifier).state = null;
    ref.invalidate(recentProjectsProvider);
  }

  Future<void> _buildIndex() async {
    setState(() => _indexing = true);
    final index = await ref.read(repoIndexerProvider).build(ref.read(projectRootProvider));
    if (mounted) {
      ref.read(repoIndexProvider.notifier).state = index;
      setState(() => _indexing = false);
    }
  }
}
