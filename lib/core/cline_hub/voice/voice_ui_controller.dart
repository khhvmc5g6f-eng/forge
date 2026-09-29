import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/hub_endpoint.dart';
import 'audio_capture.dart';
import 'tts_speaker.dart';
import 'voice_gateway_client.dart';
import 'voice_messages.dart';

class VoiceHistoryEntry {
  const VoiceHistoryEntry({required this.time, required this.result});
  final DateTime time;
  final VoiceResult result;
}

/// UI state + behaviour for talking to Forge. The phone only captures audio and
/// speaks replies; recognition, intent and execution happen on the Mac.
class VoiceUiController extends ChangeNotifier {
  VoiceUiController({
    required this.client,
    required this.capture,
    required this.speaker,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _msgSub = client.messages.listen(_onMessage);
    _levelSub = capture.level.listen((l) {
      level = l;
      notifyListeners();
    });
  }

  final VoiceGatewayClient client;
  final AudioCapture capture;
  final TtsSpeaker speaker;
  final DateTime Function() _now;
  late final StreamSubscription<VoiceServerMessage> _msgSub;
  late final StreamSubscription<double> _levelSub;

  VoiceUiState state = VoiceUiState.off;
  bool micActive = false;
  double level = 0;
  String? error;
  VoiceResult? last;
  String? interimNote;
  final List<VoiceHistoryEntry> history = [];
  String mode = 'command';
  String verbosity = 'normal';
  bool get connected => client.isConnected;

  Future<bool> connect(HubEndpoint endpoint, {int? port}) async {
    error = null;
    final ok = await client.connect(
      endpoint,
      port: port,
      mode: mode,
      verbosity: verbosity,
    );
    if (!ok) {
      error =
          'Could not reach the voice gateway: ${client.lastError ?? 'unknown error'}';
    }
    if (ok) state = VoiceUiState.listening;
    notifyListeners();
    return ok;
  }

  Future<void> disconnect() async {
    if (micActive) await _abortCapture();
    await client.disconnect();
    state = VoiceUiState.off;
    notifyListeners();
  }

  /// Push-to-talk: begin capturing. Interrupts Forge if it is speaking (barge-in).
  Future<void> pressToTalk() async {
    if (micActive) return;
    if (!connected) {
      error =
          'Voice is not connected. Set the voice gateway address in Settings.';
      notifyListeners();
      return;
    }
    if (state == VoiceUiState.speaking) {
      await speaker.stop();
      client.speechStart();
    }
    try {
      await capture.start();
      micActive = true;
      state = VoiceUiState.speechDetected;
      error = null;
    } on StateError catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Microphone unavailable: $e';
    }
    notifyListeners();
  }

  /// Release: stop capturing and send the audio for recognition.
  Future<void> releaseToTalk() async {
    if (!micActive) return;
    micActive = false;
    final audio = await capture.stop();
    level = 0;
    if (audio == null || audio.durationMs < 250) {
      state = VoiceUiState.listening;
      interimNote = 'That was too short. Hold the button while you speak.';
      notifyListeners();
      return;
    }
    interimNote = null;
    state = VoiceUiState.transcribing;
    if (!client.sendUtterance(audio.wav, audioMs: audio.durationMs)) {
      error = 'Voice connection lost.';
      state = VoiceUiState.error;
    }
    notifyListeners();
  }

  Future<void> _abortCapture() async {
    micActive = false;
    try {
      await capture.stop();
    } catch (_) {}
  }

  /// Typed input takes the same path as speech.
  void sendText(String text) {
    if (text.trim().isEmpty) return;
    if (!client.sendText(text.trim())) {
      error = 'Voice is not connected.';
      notifyListeners();
    }
  }

  void setMode(String m) {
    mode = m;
    client.configure(mode: m);
    notifyListeners();
  }

  void setVerbosity(String v) {
    verbosity = v;
    client.configure(verbosity: v);
    notifyListeners();
  }

  Future<void> _onMessage(VoiceServerMessage m) async {
    switch (m) {
      case VoiceStateMessage(:final state):
        if (!micActive) this.state = state;
      case VoiceResult():
        last = m;
        history.insert(0, VoiceHistoryEntry(time: _now(), result: m));
        if (history.length > 100) history.removeLast();
      case VoiceSpeak(:final text):
        state = VoiceUiState.speaking;
        notifyListeners();
        try {
          await speaker.speak(text);
        } finally {
          client.speechFinished();
        }
        return;
      case VoiceStopSpeaking():
        await speaker.stop();
      case VoiceErrorMessage(:final message):
        error = message;
        if (!client.isConnected) state = VoiceUiState.off;
      case VoiceRuntimeEvent() || VoiceUnknown():
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _msgSub.cancel();
    _levelSub.cancel();
    super.dispose();
  }
}
