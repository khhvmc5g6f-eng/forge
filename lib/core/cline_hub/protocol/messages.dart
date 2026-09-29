import 'dart:convert';

/// Typed view of the Cline hub WebSocket protocol (`/browser`), mirroring
/// `apps/cline-hub/src/webview-protocol.ts`. Parsing is defensive: unknown or
/// malformed frames become [UnknownMessage] and never throw.
sealed class HubMessage {
  const HubMessage();

  static HubMessage parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return UnknownMessage('?', raw);
      return _fromJson(decoded);
    } catch (_) {
      return UnknownMessage('?', raw);
    }
  }

  static HubMessage _fromJson(Map<String, dynamic> j) {
    final type = j['type'];
    if (type is! String) return UnknownMessage('?', jsonEncode(j));
    switch (type) {
      case 'status':
        return StatusMessage(_s(j['text']));
      case 'error':
        return ErrorMessage(
          _s(j['text']),
          recoverable: j['recoverable'] == true,
        );
      case 'session_started':
        return SessionStarted(_s(j['sessionId']));
      case 'session_hydrated':
        return SessionHydrated(
          sessionId: _s(j['sessionId']),
          status: j['status'] as String?,
          providerId: j['providerId'] as String?,
          modelId: j['modelId'] as String?,
          messages: [
            for (final m in _list(j['messages']))
              if (m is Map<String, dynamic>) HistoryMessage.fromJson(m),
          ],
        );
      case 'assistant_delta':
        return AssistantDelta(_s(j['text']));
      case 'reasoning_delta':
        return ReasoningDelta(_s(j['text']));
      case 'tool_event':
        final e = j['event'];
        return ToolEventMessage(
          text: _s(j['text']),
          event: e is Map<String, dynamic> ? ToolEvent.fromJson(e) : null,
        );
      case 'approval_request':
        return ApprovalRequest(
          approvalId: _s(j['approvalId']),
          sessionId: _s(j['sessionId']),
          toolName: _s(j['toolName']),
          toolCallId: _s(j['toolCallId']),
          input: j['input'],
        );
      case 'approval_resolved':
        return ApprovalResolved(_s(j['approvalId']), j['approved'] == true);
      case 'turn_done':
        final u = j['usage'];
        return TurnDone(
          finishReason: _s(j['finishReason']),
          iterations: (j['iterations'] as num?)?.toInt() ?? 0,
          usage: u is Map<String, dynamic> ? Usage.fromJson(u) : null,
        );
      case 'providers':
        return ProvidersMessage([
          for (final p in _list(j['providers']))
            if (p is Map<String, dynamic>) ProviderInfo.fromJson(p),
        ]);
      case 'models':
        return ModelsMessage(_s(j['providerId']), [
          for (final m in _list(j['models']))
            if (m is Map<String, dynamic>) ModelInfo.fromJson(m),
        ]);
      case 'sessions':
        return SessionsMessage([
          for (final s in _list(j['sessions']))
            if (s is Map<String, dynamic>) SessionSummary.fromJson(s),
        ]);
      case 'hub_state':
        return HubStateMessage(HubState.fromJson(j));
      case 'defaults':
        final d = j['defaults'];
        return DefaultsMessage(
          d is Map<String, dynamic> ? Defaults.fromJson(d) : const Defaults(),
        );
      case 'reset_done':
        return const ResetDone();
      case 'fork_done':
        return ForkDone(_s(j['newSessionId']));
      case 'fork_error':
        return ErrorMessage(_s(j['text']));
      default:
        return UnknownMessage(type, jsonEncode(j));
    }
  }
}

String _s(Object? v) => v is String ? v : (v == null ? '' : v.toString());
List<Object?> _list(Object? v) => v is List ? v : const [];

class StatusMessage extends HubMessage {
  const StatusMessage(this.text);
  final String text;
}

class ErrorMessage extends HubMessage {
  const ErrorMessage(this.text, {this.recoverable = false});
  final String text;
  final bool recoverable;
}

class SessionStarted extends HubMessage {
  const SessionStarted(this.sessionId);
  final String sessionId;
}

class SessionHydrated extends HubMessage {
  const SessionHydrated({
    required this.sessionId,
    required this.messages,
    this.status,
    this.providerId,
    this.modelId,
  });
  final String sessionId;
  final String? status;
  final String? providerId;
  final String? modelId;
  final List<HistoryMessage> messages;
}

class AssistantDelta extends HubMessage {
  const AssistantDelta(this.text);
  final String text;
}

class ReasoningDelta extends HubMessage {
  const ReasoningDelta(this.text);
  final String text;
}

class ToolEventMessage extends HubMessage {
  const ToolEventMessage({required this.text, this.event});
  final String text;
  final ToolEvent? event;
}

class ApprovalRequest extends HubMessage {
  const ApprovalRequest({
    required this.approvalId,
    required this.sessionId,
    required this.toolName,
    required this.toolCallId,
    this.input,
  });
  final String approvalId;
  final String sessionId;
  final String toolName;
  final String toolCallId;
  final Object? input;
}

class ApprovalResolved extends HubMessage {
  const ApprovalResolved(this.approvalId, this.approved);
  final String approvalId;
  final bool approved;
}

class TurnDone extends HubMessage {
  const TurnDone({
    required this.finishReason,
    required this.iterations,
    this.usage,
  });
  final String finishReason;
  final int iterations;
  final Usage? usage;
}

class ProvidersMessage extends HubMessage {
  const ProvidersMessage(this.providers);
  final List<ProviderInfo> providers;
}

class ModelsMessage extends HubMessage {
  const ModelsMessage(this.providerId, this.models);
  final String providerId;
  final List<ModelInfo> models;
}

class SessionsMessage extends HubMessage {
  const SessionsMessage(this.sessions);
  final List<SessionSummary> sessions;
}

class HubStateMessage extends HubMessage {
  const HubStateMessage(this.state);
  final HubState state;
}

class DefaultsMessage extends HubMessage {
  const DefaultsMessage(this.defaults);
  final Defaults defaults;
}

class ResetDone extends HubMessage {
  const ResetDone();
}

class ForkDone extends HubMessage {
  const ForkDone(this.newSessionId);
  final String newSessionId;
}

class UnknownMessage extends HubMessage {
  const UnknownMessage(this.type, this.raw);
  final String type;
  final String raw;
}

class Usage {
  const Usage({this.inputTokens, this.outputTokens, this.totalCost});
  final int? inputTokens;
  final int? outputTokens;
  final double? totalCost;
  factory Usage.fromJson(Map<String, dynamic> j) => Usage(
    inputTokens: (j['inputTokens'] as num?)?.toInt(),
    outputTokens: (j['outputTokens'] as num?)?.toInt(),
    totalCost: (j['totalCost'] as num?)?.toDouble(),
  );
}

enum ToolStatus { running, completed, failed }

class ToolEvent {
  const ToolEvent({
    this.toolCallId,
    this.toolName,
    required this.status,
    this.input,
    this.output,
    this.error,
  });
  final String? toolCallId;
  final String? toolName;
  final ToolStatus status;
  final Object? input;
  final Object? output;
  final String? error;
  factory ToolEvent.fromJson(Map<String, dynamic> j) => ToolEvent(
    toolCallId: j['toolCallId'] as String?,
    toolName: j['toolName'] as String?,
    status: switch (j['status']) {
      'completed' => ToolStatus.completed,
      'failed' => ToolStatus.failed,
      _ => ToolStatus.running,
    },
    input: j['input'],
    output: j['output'],
    error: j['error'] as String?,
  );
}

class HistoryToolEvent {
  const HistoryToolEvent({
    required this.id,
    required this.name,
    required this.status,
    this.input,
    this.output,
    this.error,
  });
  final String id;
  final String name;
  final ToolStatus status;
  final Object? input;
  final Object? output;
  final String? error;
}

class HistoryMessage {
  const HistoryMessage({
    required this.role,
    required this.text,
    this.reasoning,
    this.toolEvents = const [],
  });
  final String role; // user | assistant | error | meta
  final String text;
  final String? reasoning;
  final List<HistoryToolEvent> toolEvents;

  factory HistoryMessage.fromJson(Map<String, dynamic> j) => HistoryMessage(
    role: _s(j['role']),
    text: _s(j['text']),
    reasoning: j['reasoning'] as String?,
    toolEvents: [
      for (final t in _list(j['toolEvents']))
        if (t is Map<String, dynamic>)
          HistoryToolEvent(
            id: _s(t['toolCallId'] ?? t['id']),
            name: _s(t['name']),
            status: switch (t['state']) {
              'output-available' => ToolStatus.completed,
              'output-error' => ToolStatus.failed,
              _ => ToolStatus.running,
            },
            input: t['input'],
            output: t['output'],
            error: t['error'] as String?,
          ),
    ],
  );
}

class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.name,
    this.enabled = true,
    this.defaultModelId,
  });
  final String id;
  final String name;
  final bool enabled;
  final String? defaultModelId;
  factory ProviderInfo.fromJson(Map<String, dynamic> j) => ProviderInfo(
    id: _s(j['id']),
    name: _s(j['name']).isEmpty ? _s(j['id']) : _s(j['name']),
    enabled: j['enabled'] != false,
    defaultModelId: j['defaultModelId'] as String?,
  );
}

class ModelInfo {
  const ModelInfo({required this.id, required this.name});
  final String id;
  final String name;
  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
    id: _s(j['id']),
    name: _s(j['name']).isEmpty ? _s(j['id']) : _s(j['name']),
  );
}

class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    this.title,
    this.status,
    this.model,
    this.updatedAt,
  });
  final String sessionId;
  final String? title;
  final String? status;
  final String? model;
  final int? updatedAt;
  factory SessionSummary.fromJson(Map<String, dynamic> j) => SessionSummary(
    sessionId: _s(j['sessionId']),
    title: j['title'] as String?,
    status: j['status'] as String?,
    model: j['model'] as String?,
    updatedAt: (j['updatedAt'] as num?)?.toInt(),
  );
}

class HubClientInfo {
  const HubClientInfo({required this.clientType, this.displayName});
  final String clientType;
  final String? displayName;
}

class HubEvent {
  const HubEvent({
    required this.title,
    required this.body,
    required this.severity,
    required this.timestamp,
  });
  final String title;
  final String body;
  final String severity;
  final int timestamp;
}

class HubState {
  const HubState({
    this.connected = false,
    this.coreVersion,
    this.hubUptime,
    this.clients = const [],
    this.sessions = const [],
    this.events = const [],
  });
  final bool connected;
  final String? coreVersion;
  final String? hubUptime;
  final List<HubClientInfo> clients;
  final List<SessionSummary> sessions;
  final List<HubEvent> events;

  factory HubState.fromJson(Map<String, dynamic> j) => HubState(
    connected: j['connected'] == true,
    coreVersion: j['coreVersion'] as String?,
    hubUptime: j['hubUptime'] as String?,
    clients: [
      for (final c in _list(j['clients']))
        if (c is Map<String, dynamic>)
          HubClientInfo(
            clientType: _s(c['clientType']),
            displayName: c['displayName'] as String?,
          ),
    ],
    sessions: [
      for (final s in _list(j['sessions']))
        if (s is Map<String, dynamic>) SessionSummary.fromJson(s),
    ],
    events: [
      for (final e in _list(j['events']))
        if (e is Map<String, dynamic>)
          HubEvent(
            title: _s(e['title']),
            body: _s(e['body']),
            severity: _s(e['severity']),
            timestamp: (e['timestamp'] as num?)?.toInt() ?? 0,
          ),
    ],
  );
}

class Defaults {
  const Defaults({this.provider, this.model, this.workspaceRoot, this.cwd});
  final String? provider;
  final String? model;
  final String? workspaceRoot;
  final String? cwd;
  factory Defaults.fromJson(Map<String, dynamic> j) => Defaults(
    provider: j['provider'] as String?,
    model: j['model'] as String?,
    workspaceRoot: j['workspaceRoot'] as String?,
    cwd: j['cwd'] as String?,
  );
}
