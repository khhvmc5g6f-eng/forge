import 'dart:convert';

/// Messages of the Forge voice gateway protocol (see `voice/gateway.ts` in the engine repo).
sealed class VoiceServerMessage {
  const VoiceServerMessage();

  static VoiceServerMessage parse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return const VoiceUnknown();
      switch (j['type']) {
        case 'state':
          return VoiceStateMessage(VoiceUiState.fromWire('${j['state']}'));
        case 'result':
          return VoiceResult.fromJson(j);
        case 'speak':
          return VoiceSpeak('${j['text'] ?? ''}');
        case 'stop_speaking':
          return const VoiceStopSpeaking();
        case 'event':
          final e = j['event'];
          return VoiceRuntimeEvent(e is Map<String, dynamic> ? e : const {});
        case 'error':
          return VoiceErrorMessage('${j['message'] ?? 'unknown error'}');
        default:
          return const VoiceUnknown();
      }
    } catch (_) {
      return const VoiceUnknown();
    }
  }
}

enum VoiceUiState {
  off,
  listening,
  speechDetected,
  transcribing,
  understanding,
  executing,
  speaking,
  paused,
  error;

  static VoiceUiState fromWire(String s) => switch (s.toUpperCase()) {
    'LISTENING' => listening,
    'SPEECH_DETECTED' => speechDetected,
    'TRANSCRIBING' => transcribing,
    'UNDERSTANDING' => understanding,
    'EXECUTING' => executing,
    'SPEAKING' => speaking,
    'PAUSED' => paused,
    'ERROR' => error,
    _ => off,
  };

  String get label => switch (this) {
    off => 'Off',
    listening => 'Listening',
    speechDetected => 'Speech detected',
    transcribing => 'Transcribing',
    understanding => 'Understanding',
    executing => 'Working',
    speaking => 'Speaking',
    paused => 'Paused',
    error => 'Error',
  };
}

class VoiceStateMessage extends VoiceServerMessage {
  const VoiceStateMessage(this.state);
  final VoiceUiState state;
}

class VoiceIntentInfo {
  const VoiceIntentInfo({
    required this.kind,
    required this.reason,
    this.confidence = 0,
    this.interpretation = const [],
    this.needsConfirmation,
    this.needsClarification,
  });
  final String kind;
  final String reason;
  final double confidence;
  final List<String> interpretation;
  final String? needsConfirmation;
  final String? needsClarification;
}

class VoiceResult extends VoiceServerMessage {
  const VoiceResult({
    required this.heard,
    required this.text,
    required this.intent,
    this.corrections = const [],
    this.uncertain = const [],
    this.spoken,
    this.sttMs,
    this.provider,
    this.minConfidence,
  });

  final String heard;
  final String text;
  final VoiceIntentInfo intent;
  final List<String> corrections; // "spoken -> replacement"
  final List<String> uncertain; // "spoken? maybe replacement"
  final String? spoken;
  final int? sttMs;
  final String? provider;
  final double? minConfidence;

  factory VoiceResult.fromJson(Map<String, dynamic> j) {
    final i = j['intent'] is Map<String, dynamic>
        ? j['intent'] as Map<String, dynamic>
        : const <String, dynamic>{};
    List<String> pairs(Object? v, String Function(Map<String, dynamic>) f) =>
        v is List
        ? [
            for (final e in v)
              if (e is Map<String, dynamic>) f(e),
          ]
        : const [];
    return VoiceResult(
      heard: '${j['heard'] ?? ''}',
      text: '${j['text'] ?? ''}',
      corrections: pairs(
        j['corrections'],
        (e) => '${e['spoken']} -> ${e['replacement']}',
      ),
      uncertain: pairs(
        j['uncertain'],
        (e) => '${e['spoken']}? maybe ${e['replacement']}',
      ),
      spoken: j['spoken'] as String?,
      sttMs: (j['sttMs'] as num?)?.toInt(),
      provider: j['provider'] as String?,
      minConfidence: (j['minConfidence'] as num?)?.toDouble(),
      intent: VoiceIntentInfo(
        kind: '${i['kind'] ?? 'discussion'}',
        reason: '${i['reason'] ?? ''}',
        confidence: (i['confidence'] as num?)?.toDouble() ?? 0,
        interpretation: [
          for (final s
              in (i['interpretation'] is List
                  ? i['interpretation'] as List
                  : const []))
            '$s',
        ],
        needsConfirmation: i['needsConfirmation'] as String?,
        needsClarification: i['needsClarification'] as String?,
      ),
    );
  }
}

class VoiceSpeak extends VoiceServerMessage {
  const VoiceSpeak(this.text);
  final String text;
}

class VoiceStopSpeaking extends VoiceServerMessage {
  const VoiceStopSpeaking();
}

class VoiceRuntimeEvent extends VoiceServerMessage {
  const VoiceRuntimeEvent(this.event);
  final Map<String, dynamic> event;
}

class VoiceErrorMessage extends VoiceServerMessage {
  const VoiceErrorMessage(this.message);
  final String message;
}

class VoiceUnknown extends VoiceServerMessage {
  const VoiceUnknown();
}

String encodeVoiceFrame(Map<String, Object?> frame) => jsonEncode(frame);
