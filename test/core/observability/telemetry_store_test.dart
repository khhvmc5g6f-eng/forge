import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/observability/telemetry.dart';
import 'package:forge/core/observability/telemetry_store.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('forge_obs_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ObsSpan span(String name, {Map<String, dynamic> attrs = const {}}) =>
      ObsSpan(
        spanId: newSpanId(),
        traceId: 'trace-1',
        kind: SpanKind.model,
        name: name,
        sessionId: 'sess-1',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        attributes: attrs,
      );

  test('append+flush persists redacted JSONL; readAll round-trips', () async {
    final store = JsonlTelemetryStore(tempDir.path, flushThreshold: 100);
    await store.append(span('model.request', attrs: {
      'apiKey': 'sk-live-1234567890abcdef',
      'authorization': 'Bearer abcdef',
      'promptTokens': 42,
      'model': 'acme::big',
    }));
    await store.flush();

    final events = await store.readAll();
    expect(events, hasLength(1));
    expect(events.first['name'], 'model.request');
    expect(events.first['attributes']['apiKey'], '[redacted]');
    expect(events.first['attributes']['authorization'], '[redacted]');
    // Token *counts* are numbers — they must survive redaction.
    expect(events.first['attributes']['promptTokens'], 42);
    expect(events.first['attributes']['model'], 'acme::big');
    expect(store.writeFailures, 0);
  });

  test('rotation enforces the retention bound on a single large flush',
      () async {
    final store = JsonlTelemetryStore(
      tempDir.path,
      flushThreshold: 5000,
      maxLinesPerFile: 5,
      maxFiles: 2,
    );
    for (var i = 0; i < 20; i++) {
      await store.append(span('event-$i'));
    }
    await store.flush();

    final jsonlFiles = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jsonl'))
        .toList();
    expect(jsonlFiles.length, lessThanOrEqualTo(2));

    final events = await store.readAll();
    expect(events.length, lessThanOrEqualTo(10));
    // Retention keeps the newest events.
    expect(events.last['name'], 'event-19');
  });

  test('a full queue drops the oldest events and counts them', () async {
    final store = JsonlTelemetryStore(tempDir.path,
        flushThreshold: 5000, maxQueued: 4);
    for (var i = 0; i < 10; i++) {
      await store.append(span('event-$i'));
    }
    expect(store.droppedEvents, 6);
    expect(store.pendingCount, 4);
    // The queue holds the newest four.
    await store.flush();
    final events = await store.readAll();
    expect(events.first['name'], 'event-6');
    expect(events.last['name'], 'event-9');
  });

  test('write failures are counted, never thrown', () async {
    // Occupy the observability directory path with a plain file so the
    // store cannot create its directory.
    File('${tempDir.path}/.forge/observability').createSync(recursive: true);

    final store = JsonlTelemetryStore(tempDir.path, flushThreshold: 3);
    for (var i = 0; i < 5; i++) {
      await store.append(span('event-$i')); // must not throw
    }
    // Auto-flush fired at thresholds 3, 4 and 5 — every write failed and
    // every batch was re-queued, so nothing is lost while the disk is bad.
    expect(store.writeFailures, greaterThanOrEqualTo(3));
    expect(store.pendingCount, 5);
  });
}
