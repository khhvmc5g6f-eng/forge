import 'package:flutter/material.dart';

import 'ui/shell/forge_shell.dart';

/// Root widget. Named `MyApp` for compatibility with the default Flutter
/// project template's smoke test convention; kept intentionally thin so
/// rebranding (working name "Forge", architected to be renamed later per
/// the brief) only ever touches this file's `title`/`theme`.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const ForgeShell(),
    );
  }
}
