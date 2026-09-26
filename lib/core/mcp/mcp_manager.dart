import '../security/untrusted_content.dart';
import '../tools/policy_engine.dart';
import '../tools/tool.dart';
import '../tools/tool_category.dart';
import 'mcp_client.dart';
import 'mcp_transport.dart';

enum McpServerCategory {
  git,
  github,
  filesystem,
  browser,
  playwright,
  database,
  documentation,
  cloud,
  design,
  testing,
  developerTools,
  other,
}

/// Configuration for one MCP server. `trusted` defaults to false: per the
/// brief, "Do not automatically trust newly installed MCP servers" — a
/// newly added server's tool results are still routed through the same
/// [PolicyEngine] and [UntrustedContent] boundary as everything else, and
/// the UI surfaces `trusted` so the user can see which servers they have
/// deliberately vetted.
class McpServerConfig {
  McpServerConfig({
    required this.id,
    required this.name,
    required this.command,
    this.args = const [],
    this.category = McpServerCategory.other,
    this.enabled = true,
    this.trusted = false,
    this.environment,
  });

  final String id;
  final String name;
  final String command;
  final List<String> args;
  final McpServerCategory category;
  bool enabled;
  bool trusted;
  final Map<String, String>? environment;
}

class McpServerConnection {
  McpServerConnection({required this.config, required this.client});
  final McpServerConfig config;
  final McpClient client;
  String? lastError;
  DateTime? connectedAt;

  bool get isConnected => client.transport.isRunning;
}

/// Bridges one MCP tool into Forge's [Tool] interface so the [ToolGateway]
/// treats it identically to a built-in filesystem/terminal tool: same
/// policy check, same audit log, same [UntrustedContent] wrapping.
class McpBridgeTool implements Tool {
  McpBridgeTool({
    required this.serverId,
    required this._descriptor,
    required this._client,
    this._category = ToolCategory.mcp,
  });

  final String serverId;
  final McpToolDescriptor _descriptor;
  final McpClient _client;
  final ToolCategory _category;

  @override
  String get name => 'mcp__${serverId}__${_descriptor.name}';

  @override
  ToolCategory get category => _category;

  @override
  String get description => '[MCP:$serverId] ${_descriptor.description}';

  @override
  Map<String, dynamic> get parametersSchema => _descriptor.inputSchema;

  @override
  ToolInvocation describeInvocation(Map<String, dynamic> arguments) => ToolInvocation(
        category: category,
        toolName: name,
        description: '$name($arguments)',
      );

  @override
  Future<UntrustedContent> execute(Map<String, dynamic> arguments) async {
    final result = await _client.callTool(_descriptor.name, arguments);
    return UntrustedContent(source: ContentSource.mcpResource, body: result);
  }
}

/// Add / remove / enable / disable / test MCP servers, and bridge every
/// discovered tool into a [ToolGateway]. Transport creation is factored out
/// via [transportFactory] so tests can inject [FakeMcpTransport] instead of
/// spawning a real subprocess.
class McpManager {
  McpManager({
    McpTransport Function(McpServerConfig config)? transportFactory,
  }) : _transportFactory = transportFactory ?? _defaultTransportFactory;

  static McpTransport _defaultTransportFactory(McpServerConfig config) => StdioMcpTransport(
        command: config.command,
        args: config.args,
        environment: config.environment,
      );

  final McpTransport Function(McpServerConfig) _transportFactory;
  final Map<String, McpServerConnection> _connections = {};

  List<McpServerConnection> get connections => _connections.values.toList(growable: false);

  Future<McpServerConnection> addServer(McpServerConfig config) async {
    final client = McpClient(serverId: config.id, transport: _transportFactory(config));
    final connection = McpServerConnection(config: config, client: client);
    _connections[config.id] = connection;
    if (config.enabled) {
      await _connect(connection);
    }
    return connection;
  }

  Future<void> removeServer(String id) async {
    final connection = _connections.remove(id);
    if (connection != null && connection.isConnected) {
      await connection.client.disconnect();
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final connection = _connections[id];
    if (connection == null) return;
    connection.config.enabled = enabled;
    if (enabled && !connection.isConnected) {
      await _connect(connection);
    } else if (!enabled && connection.isConnected) {
      await connection.client.disconnect();
    }
  }

  Future<bool> testServer(String id) async {
    final connection = _connections[id];
    if (connection == null) return false;
    try {
      if (!connection.isConnected) {
        await _connect(connection);
      } else {
        await connection.client.refreshCapabilities();
      }
      return connection.isConnected;
    } catch (e) {
      connection.lastError = e.toString();
      return false;
    }
  }

  Future<void> _connect(McpServerConnection connection) async {
    try {
      await connection.client.connect();
      await connection.client.refreshCapabilities();
      connection.connectedAt = DateTime.now();
      connection.lastError = null;
    } catch (e) {
      connection.lastError = e.toString();
      rethrow;
    }
  }

  /// Registers every discovered tool from every connected server onto
  /// [register] (typically `gateway.register`). Call again after
  /// [testServer]/[setEnabled] to pick up newly discovered tools.
  void registerAllTools(void Function(Tool) register) {
    for (final connection in _connections.values) {
      if (!connection.isConnected) continue;
      final category = connection.config.category == McpServerCategory.playwright ||
              connection.config.category == McpServerCategory.browser
          ? ToolCategory.browser
          : ToolCategory.mcp;
      for (final descriptor in connection.client.tools) {
        register(McpBridgeTool(
          serverId: connection.config.id,
          descriptor: descriptor,
          client: connection.client,
          category: category,
        ));
      }
    }
  }
}
