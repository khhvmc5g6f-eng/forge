import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge/app.dart';
import 'package:forge/app/forge_providers.dart';
import 'package:forge/core/git/git_service.dart';
import 'package:forge/ui/shell/sidebar_section.dart';

/// A [ProcessRunner] that answers instantly with canned output, so widget
/// tests never spawn a real `git` subprocess (real process I/O doesn't
/// resolve inside `pumpAndSettle`'s synthetic frame loop without an explicit
/// `tester.runAsync`, and would otherwise time the test out).
class _FakeGitProcessRunner implements ProcessRunner {
  @override
  Future<GitResult> run(String executable, List<String> args, String workingDirectory) async {
    if (args.first == 'rev-parse' && args.contains('HEAD')) {
      return const GitResult(exitCode: 0, stdout: 'main\n', stderr: '');
    }
    return const GitResult(exitCode: 0, stdout: '', stderr: '');
  }
}

List<Override> _testOverrides() => [
      gitServiceProvider.overrideWithValue(
        GitService(repositoryRoot: '/tmp/forge-widget-test', runner: _FakeGitProcessRunner()),
      ),
    ];

void main() {
  testWidgets('ForgeShell renders every sidebar section and defaults to Tasks', (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: _testOverrides(), child: const MyApp(forceMobile: false)));
    await tester.pumpAndSettle();

    for (final section in SidebarSection.values) {
      expect(find.text(section.label), findsWidgets);
    }
    expect(find.text('No tasks yet. Create one to get started.'), findsOneWidget);
  });

  testWidgets('selecting a sidebar destination switches the visible panel', (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: _testOverrides(), child: const MyApp(forceMobile: false)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Git'));
    await tester.pumpAndSettle();

    expect(find.text('Current branch'), findsOneWidget);
  });

  testWidgets('phones start on the hub connect screen, not the desktop shell', (tester) async {
    await tester.pumpWidget(ProviderScope(overrides: _testOverrides(), child: const MyApp(forceMobile: true)));
    await tester.pumpAndSettle();

    expect(find.text('Connect to Forge'), findsOneWidget);
    expect(find.text('Hub address'), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });
}
