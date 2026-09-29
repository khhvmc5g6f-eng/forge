@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/cline_hub/protocol/hub_client.dart';
import 'package:forge/core/cline_hub/protocol/hub_endpoint.dart';
import 'package:forge/core/cline_hub/protocol/messages.dart';

/// Opt-in integration test against a real Cline hub (skipped unless configured):
///
///   FORGE_LIVE_HUB=http://127.0.0.1:8787 FORGE_LIVE_SECRET=... \
///   FORGE_LIVE_PROVIDER=ollama FORGE_LIVE_MODEL=qwen2.5:0.5b \
///   flutter test test/cline_hub/live_hub_test.dart
String? _env(String key) {
  final v = Platform.environment[key]?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

void main() {
  final hub = _env('FORGE_LIVE_HUB');

  test(
    'connects, hydrates state, streams a real turn and finishes',
    () async {
      final endpoint = HubEndpoint.tryParse(
        hub!,
        roomSecret: _env('FORGE_LIVE_SECRET'),
      )!;
      expect(
        await HubClient.probe(endpoint),
        isNull,
        reason: '/health must be reachable',
      );

      final client = HubClient();
      final seen = <HubMessage>[];
      final sub = client.messages.listen(seen.add);
      await client.connect(endpoint);
      expect(
        client.status,
        ConnectionStatus.connected,
        reason: client.lastError,
      );

      Future<T> waitFor<T extends HubMessage>(Duration timeout) async {
        final end = DateTime.now().add(timeout);
        while (DateTime.now().isBefore(end)) {
          final m = seen.whereType<T>().firstOrNull;
          if (m != null) return m;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        throw TimeoutException(
          'no $T within $timeout; saw ${seen.map((m) => m.runtimeType).toSet()}',
        );
      }

      final state = await waitFor<HubStateMessage>(const Duration(seconds: 10));
      expect(state.state.connected, isTrue);
      await waitFor<DefaultsMessage>(const Duration(seconds: 10));

      seen.clear();
      final ok = client.send({
        'type': 'send',
        'prompt': 'Reply with exactly the word: pong',
        'config': {
          'provider': _env('FORGE_LIVE_PROVIDER') ?? 'ollama',
          'model': _env('FORGE_LIVE_MODEL') ?? 'qwen2.5:0.5b',
          'mode': 'plan',
          'enableTools': true,
          'autoApproveTools': false,
        },
      });
      expect(ok, isTrue);
      final done = await waitFor<TurnDone>(const Duration(seconds: 120));
      final text = seen.whereType<AssistantDelta>().map((d) => d.text).join();
      // ignore: avoid_print
      print(
        'live reply: "${text.trim()}" finish=${done.finishReason} iterations=${done.iterations}',
      );
      expect(text.trim(), isNotEmpty);
      expect(done.finishReason, isNot('error'));

      await sub.cancel();
      await client.dispose();
    },
    skip: hub == null ? 'set FORGE_LIVE_HUB to run against a real hub' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
