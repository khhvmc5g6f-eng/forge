import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forge_engine/forge_engine.dart';

/// App-level glue: restores the saved engine on launch and turns new critical
/// engine alerts into local OS notifications while connected. Place it once,
/// above the app's screens.
class EngineAlertBridge extends ConsumerStatefulWidget {
  const EngineAlertBridge({super.key, required this.child, this.autoRestore = true});
  final Widget child;

  /// Reconnect to the saved engine on start. Tests turn this off.
  final bool autoRestore;

  @override
  ConsumerState<EngineAlertBridge> createState() => _EngineAlertBridgeState();
}

class _EngineAlertBridgeState extends ConsumerState<EngineAlertBridge> {
  StreamSubscription<EngineNotification>? _sub;

  @override
  void initState() {
    super.initState();
    final conn = ref.read(engineConnectionProvider);
    _sub = conn.criticalAlerts.listen(_onCritical);
    if (widget.autoRestore) {
      unawaited(Future(() async {
        try {
          await conn.restore();
        } catch (_) {
          // No saved engine, or the platform store is unavailable: stay unpaired.
        }
      }));
    }
  }

  Future<void> _onCritical(EngineNotification n) async {
    if (!ref.read(criticalNotificationsEnabledProvider)) return;
    final conn = ref.read(engineConnectionProvider);
    await ref.read(alertNotifierProvider).show(n, engineLabel: conn.endpoint?.label ?? 'Forge engine');
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
