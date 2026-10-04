import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ui/engine/alert_bridge.dart';
import 'ui/shell/forge_shell.dart';
import 'ui/shell/mobile_home.dart';

/// Root widget. Named `MyApp` for compatibility with the default Flutter
/// project template's smoke test convention; kept intentionally thin.
///
/// Phones and tablets (iOS/Android) get the engine remote: the chat workspace
/// that drives the Cline-Enhanced engine on your Mac plus the Control Centre
/// (operational: dashboard, circuits, usage, alerts, live flow) and Settings &
/// Connections (engine connection, provider credentials). Desktop keeps the full Forge
/// workstation shell, whose "Control Centre" section is the same engine client.
class MyApp extends StatelessWidget {
  const MyApp({super.key, this.forceMobile, this.autoRestoreEngine = true});

  /// Reconnect to the saved Forge engine on launch. Tests turn this off.
  final bool autoRestoreEngine;

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
      builder: (context, child) => EngineAlertBridge(autoRestore: autoRestoreEngine, child: child ?? const SizedBox.shrink()),
      home: mobile ? const MobileHome() : const ForgeShell(),
    );
  }
}
