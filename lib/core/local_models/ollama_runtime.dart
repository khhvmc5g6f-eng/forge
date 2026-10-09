import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Forge's **built-in** local-model runtime.
///
/// Instead of requiring Ollama as a separate, externally-installed system,
/// Forge owns the whole local stack: the server binary lives under
/// `~/.forge/runtime/ollama/bin`, pulled models live under
/// `~/.forge/runtime/ollama/models`, and the `serve` process is spawned and
/// supervised as a child of Forge itself (start/stop/pull from the Models
/// panel or `dart run tool/verify_runtime.dart`). The existing
/// `OllamaProvider` adapter then talks to the runtime's OpenAI-compatible
/// endpoint exactly as it would to any other provider — no `~/.ollama`
/// involved, nothing installed system-wide.
///
/// Everything OS- or network-shaped is injected (see the typedefs below), so
/// the lifecycle state machine, health polling and pull-stream parsing are
/// unit-tested without spawning real processes or opening sockets. Only
/// [OllamaRuntimeProvisioner.installFromZip] shells out (to `unzip`), and it
/// is tested against a committed fixture zip.

/// Lifecycle phases of the built-in runtime.
enum LocalRuntimePhase {
  /// No runtime binary under Forge's managed directory yet.
  notInstalled,

  /// The runtime is being downloaded/extracted right now.
  installing,

  /// Installed but not serving.
  stopped,

  /// `serve` has been spawned; waiting for the health endpoint to answer.
  starting,

  /// Serving — the OpenAI-compatible endpoint is live.
  running,

  /// The last start/provision attempt failed (see `OllamaRuntime.lastError`).
  failed,
}

/// Minimal handle on a spawned child process, so tests can simulate one
/// without touching dart:io.
abstract class SpawnedProcess {
  int get pid;

  /// Returns whether the signal was delivered. [force] escalates to SIGKILL.
  bool kill({bool force});

  Future<int> get exitCode;
}

class _IoSpawnedProcess implements SpawnedProcess {
  _IoSpawnedProcess(this._process);
  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  bool kill({bool force = false}) =>
      force ? _process.kill(ProcessSignal.sigkill) : _process.kill();

  @override
  Future<int> get exitCode => _process.exitCode;
}

typedef ProcessSpawner = Future<SpawnedProcess> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

typedef HealthProbe = Future<bool> Function(Uri url);

/// Provisions the runtime binary (download + extract) when missing.
typedef RuntimeInstaller = Future<void> Function(OllamaRuntime runtime);

/// Fetches the body of the `/api/tags` model-listing endpoint.
typedef TagsFetcher = Future<String> Function(Uri url);

/// Opens the NDJSON stream of a `/api/pull` request and returns its lines.
typedef PullStreamer = Future<Stream<String>> Function(Uri url, String model);

class OllamaRuntimeConfig {
  const OllamaRuntimeConfig({
    this.baseDir,
    this.host = '127.0.0.1',
    this.port = 11434,
    this.startupTimeout = const Duration(seconds: 20),
    this.pollInterval = const Duration(milliseconds: 250),
    this.gracePeriod = const Duration(seconds: 3),
    this.zipUrl = 'https://ollama.com/download/Ollama-darwin.zip',
  });

  /// Root of Forge's managed runtime. Defaults to `~/.forge/runtime/ollama`.
  final String? baseDir;
  final String host;
  final int port;
  final Duration startupTimeout;
  final Duration pollInterval;
  final Duration gracePeriod;
  final String zipUrl;
}

/// One progress line from a model pull — `/api/pull` streams
/// newline-delimited JSON objects with `status`, optionally `digest`,
/// `total` and `completed` bytes.
class OllamaPullEvent {
  const OllamaPullEvent({
    required this.status,
    this.digest,
    this.total,
    this.completed,
  });

  factory OllamaPullEvent.fromJson(Map<String, dynamic> json) => OllamaPullEvent(
        status: (json['status'] as String?) ?? '',
        digest: json['digest'] as String?,
        total: (json['total'] as num?)?.toInt(),
        completed: (json['completed'] as num?)?.toInt(),
      );

  final String status;
  final String? digest;
  final int? total;
  final int? completed;

  bool get isDone => status == 'success';

  /// Byte-fraction progress when the event carries both counters.
  double? get progress =>
      (total != null && total! > 0 && completed != null) ? completed! / total! : null;
}

class LocalRuntimeException implements Exception {
  LocalRuntimeException(this.message);
  final String message;

  @override
  String toString() => 'LocalRuntimeException: $message';
}

/// The built-in runtime itself. One instance supervises at most one `serve`
/// process; [ensureRunning] is idempotent, [stop] is graceful-then-forced.
class OllamaRuntime {
  OllamaRuntime({
    OllamaRuntimeConfig? config,
    this.onPhaseChange,
    ProcessSpawner? spawner,
    HealthProbe? healthProbe,
    RuntimeInstaller? installer,
    TagsFetcher? tagsFetcher,
    PullStreamer? pullStreamer,
  })  : config = config ?? const OllamaRuntimeConfig(),
        _spawner = spawner ?? _ioSpawn,
        _healthProbe = healthProbe ?? _httpHealthProbe,
        _installer = installer ?? OllamaRuntimeProvisioner.install,
        _tagsFetcher = tagsFetcher ?? _httpTags,
        _pullStreamer = pullStreamer ?? _httpPullStream;

  final OllamaRuntimeConfig config;
  final ProcessSpawner _spawner;
  final HealthProbe _healthProbe;
  final RuntimeInstaller _installer;
  final TagsFetcher _tagsFetcher;
  final PullStreamer _pullStreamer;

  /// Notified on every phase transition — the Riverpod layer mirrors this
  /// into `localRuntimePhaseProvider` so the Models panel renders live state.
  final void Function(LocalRuntimePhase phase)? onPhaseChange;

  LocalRuntimePhase _phase = LocalRuntimePhase.notInstalled;
  SpawnedProcess? _process;

  LocalRuntimePhase get phase => _phase;
  String? lastError;
  bool get isRunning => _phase == LocalRuntimePhase.running;

  // ---- managed paths (nothing touches ~/.ollama) ----

  static String? get _home =>
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];

  Directory get baseDir => Directory(p.normalize(config.baseDir ??
      p.join(_home ?? Directory.current.path, '.forge', 'runtime', 'ollama')));

  Directory get binDir => Directory(p.join(baseDir.path, 'bin'));
  Directory get modelsDir => Directory(p.join(baseDir.path, 'models'));
  Directory get downloadsDir => Directory(p.join(baseDir.path, 'downloads'));
  File get seedZip => File(p.join(downloadsDir.path, 'Ollama-darwin.zip'));
  File get binary =>
      File(p.join(binDir.path, Platform.isWindows ? 'ollama.exe' : 'ollama'));

  Uri get baseUrl => Uri.parse('http://${config.host}:${config.port}');
  Uri get _tagsUri => baseUrl.resolve('api/tags');
  Uri get _pullUri => baseUrl.resolve('api/pull');

  /// The OpenAI-compatible endpoint the existing `OllamaProvider` uses.
  Uri get openAiBaseUrl => baseUrl.resolve('v1/');

  bool get isInstalled => binary.existsSync();

  void _setPhase(LocalRuntimePhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    onPhaseChange?.call(phase);
  }

  // ---- lifecycle ----

  /// Provisions the runtime binary if it is missing (download + extract via
  /// the injected installer). Idempotent when already installed.
  Future<void> ensureInstalled() async {
    if (isInstalled) {
      if (_phase == LocalRuntimePhase.notInstalled ||
          _phase == LocalRuntimePhase.failed) {
        _setPhase(LocalRuntimePhase.stopped);
      }
      return;
    }
    _setPhase(LocalRuntimePhase.installing);
    try {
      await _installer(this);
    } catch (e) {
      lastError = 'install failed: $e';
      _setPhase(LocalRuntimePhase.failed);
      rethrow;
    }
    if (!isInstalled) {
      lastError = 'installer completed but ${binary.path} is missing';
      _setPhase(LocalRuntimePhase.failed);
      throw LocalRuntimeException(lastError!);
    }
    _setPhase(LocalRuntimePhase.stopped);
  }

  /// Installs (if needed), spawns the managed `serve` process on the
  /// configured host/port with Forge-owned model storage, and health-polls
  /// until the API answers. Idempotent while running.
  Future<void> ensureRunning() async {
    if (_phase == LocalRuntimePhase.running && _process != null) return;
    await ensureInstalled();
    if (_process != null) return; // a start is already in flight
    _setPhase(LocalRuntimePhase.starting);
    try {
      _process = await _spawner(binary.path, ['serve'], {
        'OLLAMA_HOST': '${config.host}:${config.port}',
        'OLLAMA_MODELS': modelsDir.path,
      });
      final deadline = DateTime.now().add(config.startupTimeout);
      while (DateTime.now().isBefore(deadline)) {
        if (await _healthProbe(_tagsUri)) {
          _setPhase(LocalRuntimePhase.running);
          return;
        }
        await Future<void>.delayed(config.pollInterval);
      }
      throw LocalRuntimeException('runtime did not answer $_tagsUri within '
          '${config.startupTimeout.inSeconds}s');
    } catch (e) {
      lastError = '$e';
      final failed = _process;
      _process = null;
      failed?.kill();
      _setPhase(LocalRuntimePhase.failed);
      throw LocalRuntimeException('built-in runtime failed to start: $e');
    }
  }

  /// Stops the managed `serve` process: SIGTERM first, SIGKILL after the
  /// configured grace period. Safe to call when not running.
  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process == null) {
      if (_phase == LocalRuntimePhase.running ||
          _phase == LocalRuntimePhase.starting) {
        _setPhase(LocalRuntimePhase.stopped);
      }
      return;
    }
    process.kill();
    try {
      await process.exitCode.timeout(config.gracePeriod);
    } on TimeoutException {
      process.kill(force: true);
    }
    _setPhase(LocalRuntimePhase.stopped);
  }

  // ---- models ----

  /// Names of the models currently in [modelsDir], via `/api/tags`.
  Future<List<String>> listModels() async {
    final body = await _tagsFetcher(_tagsUri);
    final dynamic decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const [];
    final dynamic models = decoded['models'];
    if (models is! List) return const [];
    return [
      for (final dynamic m in models)
        if (m is Map && m['name'] is String) m['name'] as String,
    ];
  }

  /// Pulls [model] through the managed runtime — it downloads into
  /// [modelsDir], never `~/.ollama`. Yields progress events; an `error`
  /// object in the stream becomes an exception.
  Stream<OllamaPullEvent> pullModel(String model) async* {
    await ensureRunning();
    final lines = await _pullStreamer(_pullUri, model);
    await for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final dynamic decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue; // tolerate partial lines / keep-alive noise
      }
      if (decoded is! Map<String, dynamic>) continue;
      final dynamic error = decoded['error'];
      if (error is String && error.isNotEmpty) {
        throw LocalRuntimeException('pull of "$model" failed: $error');
      }
      final event = OllamaPullEvent.fromJson(decoded);
      yield event;
      if (event.isDone) return;
    }
  }
}

/// Real-world provisioning: download the official distribution zip into
/// [OllamaRuntime.downloadsDir] (unless a staged copy is already there — the
/// seeding path used when a download was interrupted) and extract only the
/// CLI server binary from it. The unit tests never invoke this against the
/// network; [installFromZip] is tested with a committed fixture zip.
class OllamaRuntimeProvisioner {
  static Future<void> install(OllamaRuntime runtime) async {
    final zip = runtime.seedZip;
    if (!zip.existsSync()) {
      await downloadZip(zip, Uri.parse(runtime.config.zipUrl));
    }
    await installFromZip(zip, runtime.binDir);
  }

  /// Streaming download of the distribution zip.
  static Future<void> downloadZip(File destination, Uri url) async {
    destination.parent.createSync(recursive: true);
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', url));
      if (response.statusCode != 200) {
        throw LocalRuntimeException(
            'downloading $url failed with HTTP ${response.statusCode}');
      }
      final sink = destination.openWrite();
      await sink.addStream(response.stream);
      await sink.close();
    } finally {
      client.close();
    }
  }

  /// Extracts the `ollama` CLI server from the macOS app-bundle layout
  /// inside the distribution zip into [binDir] and makes it executable.
  static Future<void> installFromZip(File zip, Directory binDir) async {
    binDir.createSync(recursive: true);
    final result = await Process.run(
      'unzip',
      ['-j', zip.path, 'Ollama.app/Contents/Resources/macos/ollama', '-d', binDir.path],
    );
    if (result.exitCode != 0) {
      throw LocalRuntimeException(
          'unzip failed (${result.exitCode}): ${result.stderr}');
    }
    final extracted = File(
        p.join(binDir.path, Platform.isWindows ? 'ollama.exe' : 'ollama'));
    if (!extracted.existsSync()) {
      throw LocalRuntimeException(
          'unzip succeeded but ${extracted.path} is missing');
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', extracted.path]);
    }
  }
}

// ---- production seams (never exercised by the unit tests) ----

Future<SpawnedProcess> _ioSpawn(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
) async {
  final process = await Process.start(executable, arguments,
      environment: {...Platform.environment, ...environment});
  return _IoSpawnedProcess(process);
}

Future<bool> _httpHealthProbe(Uri url) async {
  try {
    final response = await http.get(url).timeout(const Duration(seconds: 2));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<String> _httpTags(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode != 200) {
    throw LocalRuntimeException(
        'GET $url failed with HTTP ${response.statusCode}');
  }
  return response.body;
}

Future<Stream<String>> _httpPullStream(Uri url, String model) async {
  final client = http.Client();
  final request = http.Request('POST', url)
    ..headers['Content-Type'] = 'application/json'
    ..body = jsonEncode({'model': model});
  final response = await client.send(request);
  if (response.statusCode != 200) {
    final body = await response.stream.bytesToString();
    client.close();
    throw LocalRuntimeException(
        'pull request failed (HTTP ${response.statusCode}): $body');
  }
  return response.stream.transform(utf8.decoder).transform(const LineSplitter());
}

