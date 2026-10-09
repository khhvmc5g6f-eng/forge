import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/local_models/ollama_runtime.dart';
import 'package:path/path.dart' as p;

void main() {
  Directory tempBase() =>
      Directory.systemTemp.createTempSync('forge_runtime_test');

  void preinstallBinary(Directory base) {
    final binDir = Directory(p.join(base.path, 'bin'))
      ..createSync(recursive: true);
    File(p.join(binDir.path, 'ollama')).writeAsStringSync('#!/bin/sh\n');
  }

  group('OllamaRuntime.ensureInstalled', () {
    test('installs the binary via the injected installer when missing', () async {
      final base = tempBase();
      final phases = <LocalRuntimePhase>[];
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(baseDir: base.path),
        onPhaseChange: phases.add,
        installer: (rt) async {
          rt.binDir.createSync(recursive: true);
          rt.binary.writeAsStringSync('#!/bin/sh\n');
        },
      );
      await runtime.ensureInstalled();
      expect(runtime.isInstalled, isTrue);
      expect(phases,
          [LocalRuntimePhase.installing, LocalRuntimePhase.stopped]);
    });

    test('is a no-op when the binary is already installed', () async {
      final base = tempBase();
      preinstallBinary(base);
      var installerRan = false;
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(baseDir: base.path),
        installer: (_) async => installerRan = true,
      );
      await runtime.ensureInstalled();
      expect(installerRan, isFalse);
      expect(runtime.phase, LocalRuntimePhase.stopped);
    });
  });

  group('OllamaRuntime.ensureRunning', () {
    test('spawns the managed serve process with Forge-owned paths', () async {
      final base = tempBase();
      preinstallBinary(base);
      late String executable;
      late List<String> arguments;
      late Map<String, String> environment;
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(seconds: 1),
          pollInterval: const Duration(milliseconds: 5),
        ),
        spawner: (exe, args, env) async {
          executable = exe;
          arguments = args;
          environment = env;
          return _FakeProcess();
        },
        healthProbe: _freeThenHealthy(),
      );
      await runtime.ensureRunning();
      expect(runtime.phase, LocalRuntimePhase.running);
      expect(executable, p.join(base.path, 'bin', 'ollama'));
      expect(arguments, ['serve']);
      expect(environment['OLLAMA_HOST'], '127.0.0.1:11434');
      expect(environment['OLLAMA_MODELS'], p.join(base.path, 'models'));
    });

    test('is idempotent while running', () async {
      final base = tempBase();
      preinstallBinary(base);
      var spawns = 0;
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(seconds: 1),
          pollInterval: const Duration(milliseconds: 5),
        ),
        spawner: (_, _, _) async {
          spawns++;
          return _FakeProcess();
        },
        healthProbe: _freeThenHealthy(),
      );
      await runtime.ensureRunning();
      await runtime.ensureRunning();
      expect(spawns, 1);
    });

    test('kills the child and fails when health never comes up', () async {
      final base = tempBase();
      preinstallBinary(base);
      final process = _FakeProcess();
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(milliseconds: 30),
          pollInterval: const Duration(milliseconds: 5),
        ),
        spawner: (_, _, _) async => process,
        healthProbe: (_) async => false,
      );
      await expectLater(
          runtime.ensureRunning(), throwsA(isA<LocalRuntimeException>()));
      expect(runtime.phase, LocalRuntimePhase.failed);
      expect(process.killed, isTrue);
      expect(runtime.lastError, isNotNull);
    });

    test('stop terminates the child and a later ensureRunning restarts it',
        () async {
      final base = tempBase();
      preinstallBinary(base);
      var spawns = 0;
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(seconds: 1),
          pollInterval: const Duration(milliseconds: 5),
          gracePeriod: const Duration(milliseconds: 10),
        ),
        spawner: (_, _, _) async {
          spawns++;
          return _FakeProcess();
        },
        healthProbe: _freeThenHealthy(),
      );
      await runtime.ensureRunning();
      await runtime.stop();
      expect(runtime.phase, LocalRuntimePhase.stopped);
      await runtime.ensureRunning();
      expect(spawns, 2);
      expect(runtime.phase, LocalRuntimePhase.running);
    });
  });

  group('OllamaRuntime models', () {
    test('listModels parses /api/tags and skips junk entries', () async {
      final runtime = OllamaRuntime(
        tagsFetcher: (_) async =>
            '{"models":[{"name":"qwen2.5-coder:7b"},{"name":"llama3.1:latest"},{"size":12}]}',
      );
      expect(await runtime.listModels(),
          ['qwen2.5-coder:7b', 'llama3.1:latest']);
    });

    test('pullModel streams progress and completes on success', () async {
      final base = tempBase();
      preinstallBinary(base);
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(seconds: 1),
          pollInterval: const Duration(milliseconds: 5),
        ),
        spawner: (_, _, _) async => _FakeProcess(),
        healthProbe: _freeThenHealthy(),
        pullStreamer: (_, _) async => Stream.fromIterable([
          '{"status":"pulling manifest"}',
          '',
          '{"status":"downloading","digest":"abc","total":100,"completed":40}',
          '{"status":"success","digest":"abc"}',
        ]),
      );
      final events = await runtime.pullModel('qwen2.5-coder:7b').toList();
      expect(events, hasLength(3));
      expect(events.first.status, 'pulling manifest');
      expect(events[1].progress, closeTo(0.4, 1e-9));
      expect(events.last.isDone, isTrue);
    });

    test('pullModel surfaces stream error objects as exceptions', () async {
      final base = tempBase();
      preinstallBinary(base);
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(seconds: 1),
          pollInterval: const Duration(milliseconds: 5),
        ),
        spawner: (_, _, _) async => _FakeProcess(),
        healthProbe: _freeThenHealthy(),
        pullStreamer: (_, _) async =>
            Stream.fromIterable(['{"error":"no space left on device"}']),
      );
      await expectLater(runtime.pullModel('big-model').toList(),
          throwsA(isA<LocalRuntimeException>()));
    });
  });

  group('OllamaRuntime foreign-server safety', () {
    test('takes the next free port instead of adopting a foreign server',
        () async {
      final base = tempBase();
      preinstallBinary(base);
      late Map<String, String> spawnEnv;
      var probeCalls = 0;
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(seconds: 1),
          pollInterval: const Duration(milliseconds: 5),
        ),
        spawner: (_, _, env) async {
          spawnEnv = env;
          return _FakeProcess();
        },
        healthProbe: (_) async {
          probeCalls++;
          if (probeCalls == 1) return true; // foreign server on 11434
          if (probeCalls == 2) return false; // 11435 is free
          return true; // our child becomes healthy there
        },
      );
      await runtime.ensureRunning();
      expect(runtime.effectivePort, 11435);
      expect(spawnEnv['OLLAMA_HOST'], '127.0.0.1:11435');
      expect(runtime.openAiBaseUrl.toString(), 'http://127.0.0.1:11435/v1/');
    });

    test('refuses to run when the child died but a foreign server answers',
        () async {
      final base = tempBase();
      preinstallBinary(base);
      final process = _FakeProcess()..kill(); // already exited
      var probeCalls = 0;
      final runtime = OllamaRuntime(
        config: OllamaRuntimeConfig(
          baseDir: base.path,
          startupTimeout: const Duration(seconds: 1),
          pollInterval: const Duration(milliseconds: 5),
        ),
        spawner: (_, _, _) async => process,
        healthProbe: (_) async => ++probeCalls != 1, // free, then "healthy"
      );
      await expectLater(
          runtime.ensureRunning(), throwsA(isA<LocalRuntimeException>()));
      expect(runtime.phase, LocalRuntimePhase.failed);
      expect(runtime.lastError, contains('foreign server'));
    });
  });

  group('OllamaRuntimeProvisioner.installFromZip', () {
    test('extracts the CLI from a distribution-shaped zip', () async {
      final base = tempBase();
      final binDir = Directory(p.join(base.path, 'bin'));
      final zip = File(p.join(
          'test', 'core', 'local_models', 'fixtures', 'fake_ollama_runtime.zip'));
      expect(zip.existsSync(), isTrue,
          reason: 'fixture zip must exist in the repo');
      await OllamaRuntimeProvisioner.installFromZip(zip, binDir);
      expect(File(p.join(binDir.path, 'ollama')).existsSync(), isTrue);
    });
  });
}

class _FakeProcess implements SpawnedProcess {
  @override
  int get pid => 4242;

  bool killed = false;
  final Completer<int> _exit = Completer<int>();

  @override
  bool kill({bool force = false}) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }

  @override
  Future<int> get exitCode => _exit.future;
}

/// Health-probe fake for the lifecycle tests: odd calls are port pre-checks
/// (report the port as free), even calls are post-spawn health checks
/// (report the managed server as healthy) — one pre-check plus one
/// successful health poll per start, including across stop/restart cycles.
HealthProbe _freeThenHealthy() {
  var calls = 0;
  return (_) async => ++calls % 2 == 0;
}
