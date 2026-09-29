import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/cline_hub/protocol/hub_client.dart';
import 'package:forge/core/cline_hub/protocol/hub_endpoint.dart';
import 'package:forge/core/cline_hub/voice/audio_capture.dart';
import 'package:forge/core/cline_hub/voice/tts_speaker.dart';
import 'package:forge/core/cline_hub/voice/voice_gateway_client.dart';
import 'package:forge/core/cline_hub/voice/voice_messages.dart';
import 'package:forge/core/cline_hub/voice/voice_orb.dart';
import 'package:forge/core/cline_hub/voice/voice_ui_controller.dart';

class _Transport implements HubTransport {
  final _in = StreamController<String>.broadcast();
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<String> get incoming => _in.stream;
  @override
  void send(String f) => sent.add(jsonDecode(f) as Map<String, dynamic>);
  @override
  Future<void> close() async => _in.close();
  void push(Map<String, Object?> m) => _in.add(jsonEncode(m));
  void drop() => _in.close();
}

class _Capture implements AudioCapture {
  final _lvl = StreamController<double>.broadcast();
  CapturedAudio? next = CapturedAudio(Uint8List(400), 1500);
  bool started = false;
  bool permission = true;
  @override
  Stream<double> get level => _lvl.stream;
  @override
  Future<bool> requestPermission() async => permission;
  @override
  Future<void> start() async {
    if (!permission) throw StateError('Microphone permission denied');
    started = true;
  }

  @override
  Future<CapturedAudio?> stop() async {
    started = false;
    return next;
  }

  @override
  Future<void> dispose() async {}
  void emit(double l) => _lvl.add(l);
}

class _Speaker implements TtsSpeaker {
  final said = <String>[];
  int stops = 0;
  Completer<void>? gate;
  @override
  Future<void> speak(String text) {
    said.add(text);
    gate = Completer<void>();
    return gate!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (gate?.isCompleted == false) gate!.complete();
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  group('VoiceServerMessage.parse', () {
    test('parses states, results and speech requests', () {
      expect(
        (VoiceServerMessage.parse('{"type":"state","state":"SPEECH_DETECTED"}')
                as VoiceStateMessage)
            .state,
        VoiceUiState.speechDetected,
      );
      final r =
          VoiceServerMessage.parse(
                jsonEncode({
                  'type': 'result',
                  'heard': 'run the tests',
                  'text': 'run the tests',
                  'corrections': [
                    {'spoken': 'air guardian', 'replacement': 'PayGateway'},
                  ],
                  'uncertain': [
                    {'spoken': 'ledgerlee', 'replacement': 'Ledgerly'},
                  ],
                  'intent': {
                    'kind': 'action',
                    'reason': 'action verb',
                    'confidence': 0.8,
                    'interpretation': ['Start task', 'run the tests'],
                    'needsConfirmation': 'Go ahead?',
                  },
                  'sttMs': 130,
                  'provider': 'whisper',
                  'minConfidence': 0.42,
                }),
              )
              as VoiceResult;
      expect(r.intent.kind, 'action');
      expect(r.intent.interpretation, ['Start task', 'run the tests']);
      expect(r.corrections.single, 'air guardian -> PayGateway');
      expect(r.uncertain.single, 'ledgerlee? maybe Ledgerly');
      expect(r.minConfidence, 0.42);
      expect(
        (VoiceServerMessage.parse('{"type":"speak","text":"Done."}')
                as VoiceSpeak)
            .text,
        'Done.',
      );
    });
    test('malformed and unknown frames never throw', () {
      expect(VoiceServerMessage.parse('nope'), isA<VoiceUnknown>());
      expect(VoiceServerMessage.parse('[1]'), isA<VoiceUnknown>());
      expect(
        VoiceServerMessage.parse('{"type":"brand_new"}'),
        isA<VoiceUnknown>(),
      );
      expect(VoiceServerMessage.parse('{"type":"result"}'), isA<VoiceResult>());
    });
    test('unknown wire states fall back to off', () {
      expect(VoiceUiState.fromWire('WAT'), VoiceUiState.off);
      expect(VoiceUiState.fromWire('transcribing'), VoiceUiState.transcribing);
    });
  });

  group('audio level', () {
    test('maps dBFS to a perceptual 0..1 level', () {
      expect(dbToLevel(-160), 0);
      expect(dbToLevel(-60), 0);
      expect(dbToLevel(-30), closeTo(0.5, 1e-9));
      expect(dbToLevel(0), 1);
      expect(dbToLevel(10), 1);
    });
  });

  group('VoiceGatewayClient', () {
    test(
      'connects to /voice on the requested port with the secret and says hello',
      () async {
        Uri? asked;
        final t = _Transport();
        final c = VoiceGatewayClient(
          transportFactory: (u) async {
            asked = u;
            return t;
          },
        );
        final e = HubEndpoint.tryParse(
          'http://192.168.1.5:8787',
          roomSecret: 's3',
        )!;
        expect(
          await c.connect(
            e,
            port: 8790,
            mode: 'conversation',
            verbosity: 'minimal',
          ),
          isTrue,
        );
        expect(asked.toString(), 'ws://192.168.1.5:8790/voice?roomSecret=s3');
        expect(t.sent.first, {
          'type': 'hello',
          'mode': 'conversation',
          'verbosity': 'minimal',
        });
        await c.dispose();
      },
    );
    test(
      'sends audio as base64 and typed text; refuses when disconnected',
      () async {
        final t = _Transport();
        final c = VoiceGatewayClient(transportFactory: (_) async => t);
        expect(c.sendText('x'), isFalse);
        await c.connect(HubEndpoint.tryParse('http://127.0.0.1:8787')!);
        expect(
          c.sendUtterance(Uint8List.fromList([82, 73, 70, 70]), audioMs: 900),
          isTrue,
        );
        expect(t.sent.last['type'], 'utterance');
        expect(base64Decode(t.sent.last['wav'] as String), [82, 73, 70, 70]);
        expect(t.sent.last['audioMs'], 900);
        c.sendText('stop');
        expect(t.sent.last, {'type': 'text', 'text': 'stop'});
        await c.dispose();
      },
    );
    test('a failed connect reports why and stays disconnected', () async {
      final c = VoiceGatewayClient(
        transportFactory: (_) async => throw const FormatException('refused'),
      );
      expect(
        await c.connect(HubEndpoint.tryParse('http://127.0.0.1:8787')!),
        isFalse,
      );
      expect(c.isConnected, isFalse);
      expect(c.lastError, contains('refused'));
    });
    test('a dropped connection is reported to listeners', () async {
      final t = _Transport();
      final c = VoiceGatewayClient(transportFactory: (_) async => t);
      await c.connect(HubEndpoint.tryParse('http://127.0.0.1:8787')!);
      final got = <VoiceServerMessage>[];
      c.messages.listen(got.add);
      t.drop();
      await settle();
      expect(c.isConnected, isFalse);
      expect(
        got.whereType<VoiceErrorMessage>().single.message,
        contains('lost'),
      );
    });
  });

  group('VoiceUiController', () {
    late _Transport t;
    late VoiceGatewayClient client;
    late _Capture cap;
    late _Speaker spk;
    late VoiceUiController v;

    setUp(() async {
      t = _Transport();
      client = VoiceGatewayClient(transportFactory: (_) async => t);
      cap = _Capture();
      spk = _Speaker();
      v = VoiceUiController(
        client: client,
        capture: cap,
        speaker: spk,
        now: () => DateTime(2026, 1, 1, 18, 42),
      );
      await v.connect(
        HubEndpoint.tryParse('http://127.0.0.1:8787')!,
        port: 8790,
      );
    });
    tearDown(() async {
      v.dispose();
      await client.dispose();
    });

    test(
      'press-to-talk shows MICROPHONE ACTIVE, release uploads the utterance',
      () async {
        await v.pressToTalk();
        expect(v.micActive, isTrue);
        expect(v.state, VoiceUiState.speechDetected);
        await v.releaseToTalk();
        expect(v.micActive, isFalse);
        expect(v.state, VoiceUiState.transcribing);
        final frame = t.sent.last;
        expect(frame['type'], 'utterance');
        expect(frame['audioMs'], 1500);
      },
    );

    test(
      'too-short audio is discarded with guidance instead of being sent',
      () async {
        cap.next = CapturedAudio(Uint8List(400), 120);
        await v.pressToTalk();
        final before = t.sent.length;
        await v.releaseToTalk();
        expect(t.sent.length, before);
        expect(v.interimNote, contains('too short'));
        expect(v.state, VoiceUiState.listening);
      },
    );

    test(
      'permission denial is reported and the mic is not marked active',
      () async {
        cap.permission = false;
        await v.pressToTalk();
        expect(v.micActive, isFalse);
        expect(v.error, contains('permission'));
      },
    );

    test(
      'shows the result, keeps history, and reflects state from the Mac',
      () async {
        t.push({'type': 'state', 'state': 'UNDERSTANDING'});
        await settle();
        expect(v.state, VoiceUiState.understanding);
        t.push({
          'type': 'result',
          'heard': 'Fix the tests',
          'text': 'Fix the tests',
          'intent': {
            'kind': 'action',
            'reason': 'action verb',
            'interpretation': ['Start task'],
          },
        });
        await settle();
        expect(v.last?.heard, 'Fix the tests');
        expect(v.history.single.result.intent.kind, 'action');
        expect(v.history.single.time, DateTime(2026, 1, 1, 18, 42));
      },
    );

    test(
      'speaks what the Mac asks it to, then tells the Mac it finished',
      () async {
        t.push({'type': 'speak', 'text': 'All tests passed.'});
        await settle();
        expect(spk.said, ['All tests passed.']);
        expect(v.state, VoiceUiState.speaking);
        spk.gate!.complete();
        await settle();
        expect(t.sent.last, {'type': 'speech_finished'});
      },
    );

    test(
      'barge-in: pressing while Forge speaks stops speech and tells the Mac',
      () async {
        t.push({'type': 'speak', 'text': 'Working on it.'});
        await settle();
        expect(v.state, VoiceUiState.speaking);
        await v.pressToTalk();
        expect(spk.stops, 1);
        expect(t.sent.any((f) => f['type'] == 'speech_start'), isTrue);
        expect(v.micActive, isTrue);
      },
    );

    test('stop_speaking from the Mac silences the phone', () async {
      t.push({'type': 'speak', 'text': 'Long reply'});
      await settle();
      t.push({'type': 'stop_speaking'});
      await settle();
      expect(spk.stops, 1);
    });

    test('live input level is exposed for the orb', () async {
      cap.emit(0.7);
      await settle();
      expect(v.level, 0.7);
    });

    test('mode and verbosity are sent to the Mac', () {
      v.setMode('dictation');
      expect(t.sent.last, {'type': 'set', 'mode': 'dictation'});
      v.setVerbosity('minimal');
      expect(t.sent.last, {'type': 'set', 'verbosity': 'minimal'});
    });

    test('pressing while disconnected explains what to do', () async {
      await v.disconnect();
      await v.pressToTalk();
      expect(v.micActive, isFalse);
      expect(v.error, contains('gateway'));
    });
  });

  group('VoiceOrb', () {
    testWidgets(
      'renders every state without errors and exposes a semantic label',
      (tester) async {
        for (final s in VoiceUiState.values) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: VoiceOrb(state: s, level: 0.5)),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.bySemanticsLabel('Voice status: ${s.label}'),
            findsOneWidget,
          );
        }
        // Idle states must not keep a ticker running.
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: VoiceOrb(state: VoiceUiState.off, level: 0)),
          ),
        );
        await tester.pump(const Duration(seconds: 5));
        expect(tester.hasRunningAnimations, isFalse);
      },
    );
  });
}
