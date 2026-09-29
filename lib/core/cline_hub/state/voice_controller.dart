import 'package:flutter/foundation.dart';

import '../services/voice_service.dart';

/// Push-to-talk dictation and optional hands-free conversation.
///
/// Safety boundary (matches the desktop design): speech only ever produces a
/// *prompt draft* and reads back completed replies. It never approves tool
/// calls and never sends an action on its own beyond the prompt the user spoke.
class VoiceController extends ChangeNotifier {
  VoiceController(this.service, {required this.onUtterance});

  final VoiceService service;

  /// Receives a finished utterance (hands-free) to submit as a prompt.
  final void Function(String text) onUtterance;

  bool available = true;
  bool listening = false;
  bool handsFree = false;
  String partial = '';
  String? error;

  Future<void> toggleListening() async =>
      listening ? stopListening() : startListening();

  Future<void> startListening() async {
    error = null;
    if (!await service.initialize()) {
      available = false;
      error = 'Speech recognition is unavailable or permission was denied.';
      notifyListeners();
      return;
    }
    listening = true;
    partial = '';
    notifyListeners();
    await service.startListening(
      (text, isFinal) {
        partial = text;
        if (isFinal) {
          listening = false;
          final finished = text.trim();
          partial = '';
          if (finished.isNotEmpty) onUtterance(finished);
        }
        notifyListeners();
      },
      onDone: () {
        listening = false;
        notifyListeners();
      },
    );
  }

  Future<void> stopListening() async {
    await service.stopListening();
    listening = false;
    notifyListeners();
  }

  Future<void> setHandsFree(bool v) async {
    handsFree = v;
    if (!v) await stopListening();
    notifyListeners();
  }

  /// Read a completed reply aloud; in hands-free mode resume listening after.
  Future<void> onReplyCompleted(String text) async {
    await service.speak(text);
    if (handsFree) await startListening();
  }

  Future<void> interrupt() async {
    await service.stopSpeaking();
    await stopListening();
  }
}
