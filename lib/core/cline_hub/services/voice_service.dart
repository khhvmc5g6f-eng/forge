import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Speech boundary so UI logic is testable without platform channels.
abstract class VoiceService {
  bool get isListening;
  Future<bool> initialize();

  /// Streams recognised text. [isFinal] is true for the last result of an utterance.
  Future<void> startListening(
    void Function(String text, bool isFinal) onResult, {
    void Function()? onDone,
  });
  Future<void> stopListening();
  Future<void> speak(String text);
  Future<void> stopSpeaking();
}

/// On-device recognition where the platform supports it (Apple SFSpeechRecognizer,
/// Android SpeechRecognizer); text-to-speech via the system voice.
class PlatformVoiceService implements VoiceService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool _listening = false;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize() async {
    if (_ready) return true;
    try {
      _ready = await _stt.initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') _listening = false;
        },
        onError: (_) => _listening = false,
      );
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  @override
  Future<void> startListening(
    void Function(String text, bool isFinal) onResult, {
    void Function()? onDone,
  }) async {
    if (!await initialize()) return;
    _listening = true;
    await _stt.listen(
      onResult: (r) {
        onResult(r.recognizedWords, r.finalResult);
        if (r.finalResult) {
          _listening = false;
          onDone?.call();
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        onDevice: true,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Future<void> stopListening() async {
    _listening = false;
    if (_ready) await _stt.stop();
  }

  @override
  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(0.5);
    await _tts.speak(
      trimmed.length > 800 ? trimmed.substring(0, 800) : trimmed,
    );
  }

  @override
  Future<void> stopSpeaking() async {
    await _tts.stop();
  }
}
