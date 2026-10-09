// End-to-end verification of Forge's built-in local-model runtime against
// the REAL binary on THIS machine: provisions it if missing (downloading
// the official zip when no staged copy exists), starts the managed `serve`
// process, lists models, and optionally pulls one into Forge's own models
// directory. No separate Ollama installation is involved anywhere.
//
// Usage:
//   dart run tool/verify_runtime.dart
//   dart run tool/verify_runtime.dart --pull qwen2.5-coder:7b
import 'dart:io';

import 'package:forge/core/local_models/ollama_runtime.dart';

Future<void> main(List<String> args) async {
  final pullIdx = args.indexOf('--pull');
  final model =
      pullIdx != -1 && pullIdx + 1 < args.length ? args[pullIdx + 1] : null;

  final runtime = OllamaRuntime(
    onPhaseChange: (phase) => stdout.writeln('[runtime] phase -> ${phase.name}'),
  );
  stdout.writeln('managed runtime dir: ${runtime.baseDir.path}');
  if (!runtime.isInstalled) {
    stdout.writeln(
        'binary missing — provisioning (downloads the official zip if no '
        'staged copy exists; this can take a while)…');
  }
  await runtime.ensureRunning();
  stdout.writeln('serving at ${runtime.baseUrl}');
  stdout.writeln('OpenAI-compatible endpoint: ${runtime.openAiBaseUrl}');

  final models = await runtime.listModels();
  stdout.writeln('models: ${models.isEmpty ? '(none yet)' : models.join(', ')}');

  if (model != null) {
    stdout.writeln('pulling $model…');
    await for (final event in runtime.pullModel(model)) {
      final pct = event.progress == null
          ? ''
          : ' ${(event.progress! * 100).toStringAsFixed(1)}%';
      stdout.writeln('  ${event.status}$pct');
    }
    stdout.writeln('pulled $model');
  }

  await runtime.stop();
  stdout.writeln('runtime stopped.');
}
