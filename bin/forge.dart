import 'dart:io';

import 'package:forge/cli/forge_cli.dart';

/// The `forge` (aliasable as `aiwork`) companion CLI. Deliberately a thin
/// wrapper: all logic lives in `lib/cli/forge_cli.dart`, which only calls
/// into `lib/core/**` — the exact same engine the desktop shell uses, per
/// the brief's "GUI and CLI must use the SAME backend agent engine."
Future<void> main(List<String> arguments) async {
  exitCode = await runForgeCli(arguments);
}
