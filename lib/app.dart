import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/cline_hub/hub_root.dart';
import 'ui/shell/forge_shell.dart';

/// Root widget. Named `MyApp` for compatibility with the default Flutter
/// project template's smoke test convention; kept intentionally thin.
///
/// Phones (iOS/Android) get the remote-control workspace that drives the
/// Cline-Enhanced engine running on your Mac. Desktop keeps the full Forge
/// workstation shell, which also has a "Forge Engine" section using the same client.
class MyApp extends StatelessWidget {
  const MyApp({super.key, this.forceMobile});

  /// Test/preview override; null = decide by platform.
  final bool? forceMobile;

  static bool get _isPhone =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final mobile = forceMobile ?? _isPhone;
    return MaterialApp(
      title: 'Forge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: mobile
          ? const Scaffold(body: SafeArea(child: HubRoot()))
          : const ForgeShell(),
    );
  }
}
