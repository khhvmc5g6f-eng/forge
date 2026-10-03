import 'package:flutter/material.dart';

import '../../core/forge_engine/engine_client.dart';
import '../../core/forge_engine/engine_connection.dart';
import 'widgets.dart';

/// Why an engine action is unavailable right now, or null when it can run.
/// Actions come from the engine's discovered capabilities, never assumed.
String? actionBlockedReason(EngineConnection c, String action) {
  if (!c.isConnected) return 'Not connected to the engine';
  if (!c.capabilitiesKnown) return 'Checking what this engine allows…';
  if (c.capabilities.readOnly) return 'This engine is read-only: it has no action API yet (see docs/ENGINE_API.md)';
  if (!c.capabilities.supports(action)) return 'This engine does not support "$action" yet (see docs/ENGINE_API.md)';
  return null;
}

/// Runs [action] through the connection, then reports the engine's own
/// message (or error) in a snackbar. Returns true on success.
Future<bool> runEngineAction(
  BuildContext context,
  EngineConnection conn,
  Future<EngineActionResult> Function(EngineClient c) action, {
  String? success,
}) async {
  try {
    final r = await conn.run(action);
    if (context.mounted) toast(context, success ?? r.message);
    return r.ok;
  } on EngineException catch (e) {
    if (context.mounted) toast(context, e.message);
    return false;
  }
}
