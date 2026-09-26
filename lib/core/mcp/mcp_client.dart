import 'dart:async';

import 'mcp_transport.dart';

class McpToolDescriptor {
  const McpToolDescriptor({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  factory McpToolDescriptor.fromJson(Map<String, dynamic> json) => McpToolDescriptor(
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        inputSchema: (json['inputSchema'] as Map<String, dynamic>?) ?? const {'type': 'object'},
      );
}

class McpResourceDescriptor {
  const McpResourceDescriptor({required this.uri, required this.name, this.mimeType});
  final String uri;
  final String name;
  final String? mimeType;

  factory McpResourceDescriptor.fromJson(Map<String, dynamic> json) => McpResourceDescriptor(
        uri: json['uri'] as String,
        name: json['name'] as String? ?? json['uri'] as String,
        mimeType: json['mimeType'] as String?,
      );
}

class McpPromptDescriptor {
  const McpPromptDescriptor({required this.name, required this.description});
  final String name;
  final String description;

  factory McpPromptDescriptor.fromJson(Map<String, dynamic> json) => McpPromptDescriptor(
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
      );
}

class McpRpcException implements Exception {
  McpRpcException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'MCP RPC error $code: $message';
}

/// A minimal JSON-RPC 2.0 client for one MCP server connection, implementing
/// just the parts of the spec Forge needs: `initialize`, `tools/list`,
/// `tools/call`, `resources/list`, `resources/read`, `prompts/list`. Forge
/// treats every capability the server reports dynamically — nothing about a
/// server's tool set is hard-coded, per the brief.
class McpClient {
  McpClient({required this.serverId, required this.transport});

  final String serverId;
  final McpTransport transport;

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;
  StreamSubscription<Map<String, dynamic>>? _sub;

  List<McpToolDescriptor> tools = [];
  List<McpResourceDescriptor> resources = [];
  List<McpPromptDescriptor> prompts = [];
  Map<String, dynamic> serverInfo = const {};

  Future<void> connect({Map<String, dynamic>? clientInfo}) async {
    await transport.start();
    _sub = transport.incoming.listen(_handleIncoming);
    final initResult = await _request('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': <String, dynamic>{},
      'clientInfo': clientInfo ?? {'name': 'forge', 'version': '0.1.0'},
    });
    serverInfo = (initResult['serverInfo'] as Map<String, dynamic>?) ?? const {};
    await transport.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
  }

  Future<void> disconnect() async {
    await _sub?.cancel();
    await transport.stop();
  }

  Future<void> refreshCapabilities() async {
    tools = await _listTools();
    resources = await _listResources();
    prompts = await _listPrompts();
  }

  Future<List<McpToolDescriptor>> _listTools() async {
    try {
      final result = await _request('tools/list', {});
      final list = (result['tools'] as List<dynamic>? ?? const []);
      return list
          .map((e) => McpToolDescriptor.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } on McpRpcException {
      return const [];
    }
  }

  Future<List<McpResourceDescriptor>> _listResources() async {
    try {
      final result = await _request('resources/list', {});
      final list = (result['resources'] as List<dynamic>? ?? const []);
      return list
          .map((e) => McpResourceDescriptor.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } on McpRpcException {
      return const [];
    }
  }

  Future<List<McpPromptDescriptor>> _listPrompts() async {
    try {
      final result = await _request('prompts/list', {});
      final list = (result['prompts'] as List<dynamic>? ?? const []);
      return list
          .map((e) => McpPromptDescriptor.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } on McpRpcException {
      return const [];
    }
  }

  Future<String> callTool(String name, Map<String, dynamic> arguments) async {
    final result = await _request('tools/call', {'name': name, 'arguments': arguments});
    final content = result['content'] as List<dynamic>? ?? const [];
    final buffer = StringBuffer();
    for (final block in content) {
      final map = block as Map<String, dynamic>;
      if (map['type'] == 'text') buffer.writeln(map['text'] as String? ?? '');
    }
    if (result['isError'] == true) {
      throw McpRpcException(-1, buffer.toString());
    }
    return buffer.toString();
  }

  Future<String> readResource(String uri) async {
    final result = await _request('resources/read', {'uri': uri});
    final contents = result['contents'] as List<dynamic>? ?? const [];
    final buffer = StringBuffer();
    for (final block in contents) {
      final map = block as Map<String, dynamic>;
      buffer.writeln(map['text'] as String? ?? '');
    }
    return buffer.toString();
  }

  Future<Map<String, dynamic>> _request(String method, Map<String, dynamic> params) async {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    await transport.send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw McpRpcException(-2, 'Timed out waiting for $method response from $serverId');
      },
    );
  }

  void _handleIncoming(Map<String, dynamic> message) {
    final id = message['id'];
    if (id == null) return; // notification from server; ignored for now.
    final completer = _pending.remove(id is int ? id : int.tryParse(id.toString()));
    if (completer == null) return;
    if (message.containsKey('error')) {
      final error = message['error'] as Map<String, dynamic>;
      completer.completeError(McpRpcException(
        (error['code'] as num?)?.toInt() ?? -1,
        error['message'] as String? ?? 'unknown MCP error',
      ));
    } else {
      completer.complete((message['result'] as Map<String, dynamic>?) ?? const {});
    }
  }
}
