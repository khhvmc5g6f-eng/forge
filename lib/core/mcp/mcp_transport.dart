import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A JSON-RPC 2.0 transport for one MCP server connection. MCP's stdio
/// transport frames each message as a single line of JSON on the child
/// process's stdin/stdout — no LSP-style `Content-Length` headers — which is
/// what [StdioMcpTransport] implements. HTTP/SSE transports implement the
/// same interface; the rest of Forge's MCP layer ([McpClient]) never knows
/// which one it's talking to.
abstract class McpTransport {
  Future<void> start();
  Future<void> send(Map<String, dynamic> message);
  Stream<Map<String, dynamic>> get incoming;
  Future<void> stop();
  bool get isRunning;
}

/// Spawns [command] with [args] and speaks newline-delimited JSON-RPC over
/// its stdin/stdout, per the MCP specification's stdio transport.
class StdioMcpTransport implements McpTransport {
  StdioMcpTransport({
    required this.command,
    this.args = const [],
    this.workingDirectory,
    this.environment,
  });

  final String command;
  final List<String> args;
  final String? workingDirectory;
  final Map<String, String>? environment;

  Process? _process;
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final List<String> stderrLog = [];

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  bool get isRunning => _process != null;

  @override
  Future<void> start() async {
    _process = await Process.start(
      command,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    _stdoutSub = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      try {
        final decoded = jsonDecode(line) as Map<String, dynamic>;
        _incoming.add(decoded);
      } catch (_) {
        // Non-JSON line on stdout: MCP servers must not write logs there,
        // but tolerate it rather than crashing the connection.
      }
    });
    _stderrSub = _process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          stderrLog.add,
        );
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    final process = _process;
    if (process == null) {
      throw StateError('MCP transport for $command has not been started.');
    }
    process.stdin.writeln(jsonEncode(message));
    await process.stdin.flush();
  }

  @override
  Future<void> stop() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _process?.kill();
    _process = null;
    await _incoming.close();
  }
}

/// In-memory transport for tests: lets a test act as the "server" side by
/// pushing responses and observing what the client sent.
class FakeMcpTransport implements McpTransport {
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> sent = [];
  bool _running = false;

  @override
  Stream<Map<String, dynamic>> get incoming => _incoming.stream;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    sent.add(message);
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _incoming.close();
  }

  /// Test hook: simulate the server responding.
  void pushIncoming(Map<String, dynamic> message) => _incoming.add(message);
}
