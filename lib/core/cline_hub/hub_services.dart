import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'protocol/hub_client.dart';
import 'protocol/hub_endpoint.dart';
import 'services/settings_store.dart';
import 'services/voice_service.dart';
import 'state/session_controller.dart';
import 'state/voice_controller.dart';

/// Everything the remote-control client needs, wired once.
///
/// Forge drives the Cline-Enhanced engine over its hub WebSocket; this object
/// owns that connection, the persisted settings and the voice layer.
class HubServices {
  HubServices({
    SettingsStore? store,
    VoiceService? voiceService,
    HubClient? client,
  }) : store = store ?? PlatformSettingsStore(),
       client = client ?? HubClient() {
    controller = SessionController(
      client: this.client,
      store: this.store,
      onReply: (text) {
        if (controller.speakReplies || voice.handsFree) {
          voice.onReplyCompleted(text);
        }
      },
    );
    voice = VoiceController(
      voiceService ?? PlatformVoiceService(),
      onUtterance: (t) => controller.send(t),
    );
  }

  final SettingsStore store;
  final HubClient client;
  late final SessionController controller;
  late final VoiceController voice;

  SavedConnection? savedConnection;
  bool booted = false;

  /// Loads preferences and, when a hub was remembered, reconnects to it.
  Future<void> boot({bool autoConnect = true}) async {
    if (booted) return;
    // A stuck keystore / preferences channel must never trap the UI on a spinner.
    const limit = Duration(seconds: 3);
    try {
      await controller.restorePrefs().timeout(limit);
    } catch (_) {}
    try {
      savedConnection = await store.loadConnection().timeout(limit);
    } catch (_) {
      savedConnection = null;
    }
    final saved = savedConnection;
    if (autoConnect && saved != null) {
      final e = HubEndpoint.tryParse(saved.url, roomSecret: saved.roomSecret);
      if (e != null) await controller.connect(e, remember: false);
    }
    booted = true;
  }

  void dispose() {
    voice.dispose();
    controller.dispose();
    client.dispose();
  }
}

final hubServicesProvider = Provider<HubServices>((ref) {
  final services = HubServices();
  ref.onDispose(services.dispose);
  return services;
});
