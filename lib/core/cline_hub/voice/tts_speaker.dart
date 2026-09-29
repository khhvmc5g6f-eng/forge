import 'package:flutter_tts/flutter_tts.dart';

/// Speaks text with the device's own voices (offline).
abstract class TtsSpeaker {
  /// Completes when speech finishes or is stopped.
  Future<void> speak(String text);
  Future<void> stop();
}

class FlutterTtsSpeaker implements TtsSpeaker {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(0.5);
    // Prefer a British English voice where the platform has one.
    try {
      await _tts.setLanguage('en-GB');
    } catch (_) {}
  }

  @override
  Future<void> speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _configure();
    await _tts.speak(t.length > 800 ? t.substring(0, 800) : t);
  }

  @override
  Future<void> stop() => _tts.stop();
}
