import 'package:forge/core/cline_hub/protocol/hub_endpoint.dart';
import 'package:forge/core/cline_hub/protocol/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HubEndpoint', () {
    test('bare local hosts default to http, remote to https', () {
      expect(HubEndpoint.tryParse('192.168.1.20:8787')!.baseUrl.scheme, 'http');
      expect(HubEndpoint.tryParse('mac.local:8787')!.baseUrl.scheme, 'http');
      expect(HubEndpoint.tryParse('hub.example.com')!.baseUrl.scheme, 'https');
    });

    test('websocket URI carries the secret; origin and label never do', () {
      final e = HubEndpoint.tryParse(
        'http://192.168.1.20:8787',
        roomSecret: ' s3cret ',
      )!;
      expect(
        e.webSocketUri.toString(),
        'ws://192.168.1.20:8787/browser?roomSecret=s3cret',
      );
      expect(e.origin, 'http://192.168.1.20:8787');
      expect(e.label, '192.168.1.20:8787');
      expect(e.origin.contains('s3cret'), isFalse);
      expect(e.label.contains('s3cret'), isFalse);
    });

    test('https maps to wss and blank secret is dropped', () {
      final e = HubEndpoint.tryParse(
        'https://hub.example.com',
        roomSecret: '  ',
      )!;
      expect(e.webSocketUri.toString(), 'wss://hub.example.com/browser');
      expect(e.roomSecret, isNull);
    });

    test('flags cleartext to non-local hosts only', () {
      expect(
        HubEndpoint.tryParse('http://192.168.1.5:8787')!.isInsecureRemote,
        isFalse,
      );
      expect(
        HubEndpoint.tryParse('http://10.0.2.2:8787')!.isInsecureRemote,
        isFalse,
      );
      expect(
        HubEndpoint.tryParse('http://172.20.1.1:8787')!.isInsecureRemote,
        isFalse,
      );
      expect(
        HubEndpoint.tryParse('http://172.32.1.1:8787')!.isInsecureRemote,
        isTrue,
      );
      expect(
        HubEndpoint.tryParse('http://8.8.8.8:8787')!.isInsecureRemote,
        isTrue,
      );
      expect(
        HubEndpoint.tryParse('https://8.8.8.8')!.isInsecureRemote,
        isFalse,
      );
    });

    test('rejects junk and non-http schemes', () {
      expect(HubEndpoint.tryParse(''), isNull);
      expect(HubEndpoint.tryParse('   '), isNull);
      expect(HubEndpoint.tryParse('ftp://x.example.com'), isNull);
    });
  });

  group('HubMessage.parse', () {
    test('parses core turn messages', () {
      expect(
        HubMessage.parse('{"type":"assistant_delta","text":"hi"}'),
        isA<AssistantDelta>().having((m) => m.text, 'text', 'hi'),
      );
      final done =
          HubMessage.parse(
                '{"type":"turn_done","finishReason":"completed","iterations":2,"usage":{"inputTokens":10,"outputTokens":5,"totalCost":0.5}}',
              )
              as TurnDone;
      expect(done.iterations, 2);
      expect(done.usage!.totalCost, 0.5);
    });

    test('parses tool events and approvals', () {
      final t =
          HubMessage.parse(
                '{"type":"tool_event","text":"x","event":{"toolCallId":"t1","toolName":"editor","status":"completed","output":"ok"}}',
              )
              as ToolEventMessage;
      expect(t.event!.status, ToolStatus.completed);
      final a =
          HubMessage.parse(
                '{"type":"approval_request","approvalId":"a1","sessionId":"s","toolName":"run_commands","toolCallId":"t","input":{"cmd":"ls"}}',
              )
              as ApprovalRequest;
      expect(a.toolName, 'run_commands');
    });

    test('hydration maps history roles and tool states', () {
      final h =
          HubMessage.parse(
                '{"type":"session_hydrated","sessionId":"s1","messages":[{"role":"user","text":"q"},{"role":"assistant","text":"a","toolEvents":[{"id":"1","name":"read_files","state":"output-error","error":"boom"}]}]}',
              )
              as SessionHydrated;
      expect(h.messages.length, 2);
      expect(h.messages[1].toolEvents.single.status, ToolStatus.failed);
    });

    test('malformed or unknown frames never throw', () {
      expect(HubMessage.parse('not json'), isA<UnknownMessage>());
      expect(HubMessage.parse('[1,2]'), isA<UnknownMessage>());
      expect(HubMessage.parse('{"nope":1}'), isA<UnknownMessage>());
      expect(
        HubMessage.parse('{"type":"brand_new_thing"}'),
        isA<UnknownMessage>(),
      );
      expect(
        HubMessage.parse(
          '{"type":"sessions","sessions":[1,"x",{"sessionId":"ok"}]}',
        ),
        isA<SessionsMessage>().having((m) => m.sessions.length, 'n', 1),
      );
    });
  });
}
