import 'package:forge/core/cline_hub/protocol/hub_client.dart';
import 'package:forge/core/cline_hub/protocol/messages.dart';
import 'package:forge/core/cline_hub/services/settings_store.dart';
import 'package:forge/core/cline_hub/state/autonomy.dart';
import 'package:forge/core/cline_hub/state/chat_items.dart';
import 'package:forge/core/cline_hub/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _ThrowingStore extends MemorySettingsStore {
  @override
  Future<void> saveConnection(SavedConnection c) async =>
      throw StateError('keystore rejected write');
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('ChatTranscript', () {
    test('streams deltas into one assistant bubble and finishes the turn', () {
      final t = ChatTranscript()..addUser('hi');
      t.appendAssistant('Hel');
      t.appendAssistant('lo');
      expect(t.items.length, 2);
      expect((t.items.last as AssistantItem).text, 'Hello');
      expect((t.items.last as AssistantItem).streaming, isTrue);
      t.finishTurn();
      expect((t.items.last as AssistantItem).streaming, isFalse);
    });

    test(
      'tool events upsert by id and sit before the open assistant bubble',
      () {
        final t = ChatTranscript()..addUser('go');
        t.upsertTool(
          const ToolEvent(
            toolCallId: 'a',
            toolName: 'editor',
            status: ToolStatus.running,
          ),
          fallbackText: '',
        );
        t.upsertTool(
          const ToolEvent(
            toolCallId: 'a',
            toolName: 'editor',
            status: ToolStatus.completed,
            output: 'ok',
          ),
          fallbackText: '',
        );
        expect(t.items.whereType<ToolItem>().length, 1);
        expect(
          t.items.whereType<ToolItem>().single.status,
          ToolStatus.completed,
        );
        expect(t.items.last, isA<AssistantItem>());
      },
    );

    test('an empty placeholder is dropped when the turn ends', () {
      final t = ChatTranscript()..addUser('x');
      t.finishTurn();
      expect(t.items.whereType<AssistantItem>(), isEmpty);
    });
  });

  group('AutonomyLevel', () {
    test(
      'advisory is plan mode without auto-approval; orchestrated adds spawn/teams',
      () {
        final a = AutonomyLevel.advisory.toConfig(provider: 'p', model: 'm');
        expect(a['mode'], 'plan');
        expect(a['autoApproveTools'], false);
        expect(a['provider'], 'p');
        final o = AutonomyLevel.orchestrated.toConfig();
        expect(o['enableSpawn'], true);
        expect(o['enableTeams'], true);
        expect(o['autoApproveTools'], true);
        expect(o.containsKey('provider'), isFalse);
      },
    );

    test('unknown persisted names fall back to the safe assisted level', () {
      expect(AutonomyLevel.fromName('bogus'), AutonomyLevel.assisted);
      expect(AutonomyLevel.fromName(null), AutonomyLevel.assisted);
    });
  });

  group('SessionController', () {
    late FakeNetwork net;
    late HubClient client;
    late MemorySettingsStore store;
    late SessionController c;
    final replies = <String>[];

    setUp(() async {
      replies.clear();
      net = FakeNetwork();
      client = HubClient(
        transportFactory: net.connect,
        maxReconnectAttempts: 2,
      );
      store = MemorySettingsStore();
      c = SessionController(client: client, store: store, onReply: replies.add);
      await c.connect(endpoint());
    });

    tearDown(() async {
      c.dispose();
      await client.dispose();
    });

    test('connect sends ready and remembers the connection', () {
      expect(net.current.sent.first, {'type': 'ready'});
      expect(store.connection!.url, 'http://127.0.0.1:8787');
    });

    test(
      'a failing keystore never breaks connecting and is reported',
      () async {
        final n = FakeNetwork();
        final cl = HubClient(transportFactory: n.connect);
        final ctl = SessionController(client: cl, store: _ThrowingStore());
        await ctl.connect(endpoint());
        expect(ctl.isConnected, isTrue);
        expect(ctl.banner, contains('would not store'));
        ctl.dispose();
        await cl.dispose();
      },
    );

    test('send requires provider/model, then emits a well-formed frame', () {
      expect(c.send('hello'), contains('provider'));
      c.apply(
        const DefaultsMessage(Defaults(provider: 'ollama', model: 'qwen')),
      );
      expect(c.send('  '), 'Nothing to send.');
      expect(c.send('hello'), isNull);
      final frame = net.current.sent.last;
      expect(frame['type'], 'send');
      expect(frame['prompt'], 'hello');
      expect((frame['config'] as Map)['provider'], 'ollama');
      expect((frame['config'] as Map)['mode'], 'act');
      expect(c.turnInProgress, isTrue);
      expect(c.send('again'), contains('already running'));
    });

    test('a full turn streams, finishes, and reports the reply once', () {
      c.apply(const DefaultsMessage(Defaults(provider: 'p', model: 'm')));
      c.send('q');
      c.apply(const AssistantDelta('Hel'));
      c.apply(const AssistantDelta('lo'));
      c.apply(
        const TurnDone(
          finishReason: 'completed',
          iterations: 1,
          usage: Usage(inputTokens: 3, outputTokens: 2),
        ),
      );
      expect(c.turnInProgress, isFalse);
      expect(replies, ['Hello']);
      expect(c.lastUsage!.inputTokens, 3);
    });

    test('an empty hydration during a running turn keeps the user message', () {
      c.apply(const DefaultsMessage(Defaults(provider: 'p', model: 'm')));
      c.send('hello');
      c.apply(const SessionStarted('s1'));
      c.apply(const SessionHydrated(sessionId: 's1', messages: []));
      c.apply(const AssistantDelta('hi'));
      final items = c.transcript.items;
      expect(items.first, isA<UserItem>());
      expect((items.first as UserItem).text, 'hello');
      expect(c.turnInProgress, isTrue);
    });

    test('hydration when idle replaces the transcript (attach / resume)', () {
      c.apply(
        const SessionHydrated(
          sessionId: 's2',
          messages: [
            HistoryMessage(role: 'user', text: 'old q'),
            HistoryMessage(role: 'assistant', text: 'old a'),
          ],
        ),
      );
      expect(c.transcript.items.length, 2);
      expect(c.sessionId, 's2');
    });

    test('approvals: dedupe, respond sends a frame and clears it', () {
      const req = ApprovalRequest(
        approvalId: 'a1',
        sessionId: 's',
        toolName: 'run_commands',
        toolCallId: 't',
      );
      c.apply(req);
      c.apply(req);
      expect(c.approvals.length, 1);
      c.respondToApproval('a1', true);
      expect(net.current.sent.last, {
        'type': 'approval_response',
        'approvalId': 'a1',
        'approved': true,
      });
      expect(c.approvals, isEmpty);
    });

    test('a hub-resolved approval disappears', () {
      c.apply(
        const ApprovalRequest(
          approvalId: 'a2',
          sessionId: 's',
          toolName: 't',
          toolCallId: 'x',
        ),
      );
      c.apply(const ApprovalResolved('a2', false));
      expect(c.approvals, isEmpty);
    });

    test('non-recoverable errors end the turn; recoverable ones do not', () {
      c.apply(const DefaultsMessage(Defaults(provider: 'p', model: 'm')));
      c.send('q');
      c.apply(const ErrorMessage('plan-mode guard', recoverable: true));
      expect(c.turnInProgress, isTrue);
      c.apply(const ErrorMessage('provider down'));
      expect(c.turnInProgress, isFalse);
    });

    test(
      'changing provider picks its default model and persists prefs',
      () async {
        c.apply(
          const ProvidersMessage([
            ProviderInfo(id: 'a', name: 'A', defaultModelId: 'a1'),
            ProviderInfo(id: 'b', name: 'B', defaultModelId: 'b1'),
          ]),
        );
        await c.select(provider: 'b');
        expect(c.model, 'b1');
        await c.setAutonomy(AutonomyLevel.orchestrated);
        expect(store.prefs.provider, 'b');
        expect(store.prefs.autonomy, 'orchestrated');
      },
    );

    test('new session and abort send the right frames', () {
      c.abort();
      expect(net.current.sent.last, {'type': 'abort'});
      c.newSession();
      expect(net.current.sent.last, {'type': 'reset'});
    });

    test(
      'reconnect rehydrates the attached session and drops stale approvals',
      () async {
        c.apply(const SessionStarted('sess-1'));
        c.apply(
          const ApprovalRequest(
            approvalId: 'a',
            sessionId: 'sess-1',
            toolName: 't',
            toolCallId: 'x',
          ),
        );
        net.current.drop();
        await settle();
        expect(c.status, ConnectionStatus.reconnecting);
        expect(c.approvals, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        expect(c.status, ConnectionStatus.connected);
        expect(net.transports.length, 2);
        final frames = net.current.sent.map((f) => f['type']).toList();
        expect(frames, containsAllInOrder(['ready', 'attachSession']));
      },
    );
  });

  group('HubClient', () {
    test('backoff doubles, caps at 30s, and jitter only lengthens', () {
      expect(HubClient.backoff(1).inSeconds, 1);
      expect(HubClient.backoff(2).inSeconds, 2);
      expect(HubClient.backoff(5).inSeconds, 16);
      expect(HubClient.backoff(9).inSeconds, 30);
      expect(HubClient.backoff(1, jitter: 1).inMilliseconds, 1250);
    });

    test(
      'initial connection failure gives up (no retry loop) and reports why',
      () async {
        final net = FakeNetwork()..failNext = 1;
        final client = HubClient(transportFactory: net.connect);
        await client.connect(endpoint());
        expect(client.status, ConnectionStatus.disconnected);
        expect(client.lastError, contains('refused'));
        await client.dispose();
      },
    );

    test('gives up after the bounded number of reconnect attempts', () async {
      final net = FakeNetwork();
      final client = HubClient(
        transportFactory: net.connect,
        maxReconnectAttempts: 1,
      );
      await client.connect(endpoint());
      net.failNext = 5;
      net.current.drop();
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(client.status, ConnectionStatus.disconnected);
      await client.dispose();
    });

    test('send is refused (not queued) when not connected', () async {
      final client = HubClient(transportFactory: FakeNetwork().connect);
      expect(client.send({'type': 'ready'}), isFalse);
      await client.dispose();
    });
  });
}
