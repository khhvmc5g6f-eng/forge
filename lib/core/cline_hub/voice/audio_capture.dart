import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart' as pp;
import 'package:record/record.dart';

/// Microphone boundary. [level] is the REAL input level in 0..1 (drives the orb).
abstract class AudioCapture {
  Stream<double> get level;
  Future<bool> requestPermission();

  /// Begins recording; throws [StateError] if permission is missing.
  Future<void> start();

  /// Stops and returns a 16 kHz mono 16-bit WAV file's bytes plus duration, or null if nothing was captured.
  Future<CapturedAudio?> stop();
  Future<void> dispose();
}

class CapturedAudio {
  const CapturedAudio(this.wav, this.durationMs);
  final Uint8List wav;
  final int durationMs;
}

/// dBFS (-160..0) to a perceptual 0..1 level; -60 dB and below reads as silence.
double dbToLevel(double db) => ((db + 60) / 60).clamp(0.0, 1.0);

class RecordAudioCapture implements AudioCapture {
  final AudioRecorder _rec = AudioRecorder();
  final _level = StreamController<double>.broadcast();
  StreamSubscription<Amplitude>? _ampSub;
  String? _path;
  DateTime? _startedAt;

  @override
  Stream<double> get level => _level.stream;

  @override
  Future<bool> requestPermission() => _rec.hasPermission();

  @override
  Future<void> start() async {
    if (!await _rec.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final dir = await pp.getTemporaryDirectory();
    _path =
        '${dir.path}/forge-voice-${DateTime.now().microsecondsSinceEpoch}.wav';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ),
      path: _path!,
    );
    _startedAt = DateTime.now();
    _ampSub = _rec
        .onAmplitudeChanged(const Duration(milliseconds: 60))
        .listen((a) => _level.add(dbToLevel(a.current)));
  }

  @override
  Future<CapturedAudio?> stop() async {
    await _ampSub?.cancel();
    _ampSub = null;
    _level.add(0);
    final started = _startedAt;
    final path = await _rec.stop() ?? _path;
    _startedAt = null;
    if (path == null) return null;
    final f = File(path);
    try {
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      final ms = started == null
          ? 0
          : DateTime.now().difference(started).inMilliseconds;
      return bytes.length < 200 ? null : CapturedAudio(bytes, ms);
    } finally {
      // Raw audio is never kept on the device.
      if (await f.exists()) await f.delete();
    }
  }

  @override
  Future<void> dispose() async {
    await _ampSub?.cancel();
    await _level.close();
    await _rec.dispose();
  }
}
