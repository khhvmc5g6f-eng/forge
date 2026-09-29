import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/hub_client.dart';
import '../protocol/hub_endpoint.dart';
import '../protocol/messages.dart';
import '../services/settings_store.dart';
import 'autonomy.dart';
import 'chat_items.dart';

/// Owns the hub connection and exposes UI state. All hub semantics live here;
/// widgets only read state and call intent methods.
class SessionController extends ChangeNotifier {
  SessionController({required this.client, required this.store, this.onReply}) {
    _msgSub = client.messages.listen(apply);
    _statusSub = client.statusStream.listen(_onStatus);
  }

  final HubClient client;
  final SettingsStore store;

  /// Called with the final text of each completed assistant turn (e.g. for TTS).
  final void Function(String text)? onReply;

  final ChatTranscript transcript = ChatTranscript();
  late final StreamSubscription<HubMessage> _msgSub;
  late final StreamSubscription<ConnectionStatus> _statusSub;

  HubEndpoint? endpoint;
  HubState hubState = const HubState();
  Defaults defaults = const Defaults();
  List<ProviderInfo> providers = const [];
  final Map<String, List<ModelInfo>> models = {};
  List<SessionSummary> sessions = const [];
  final List<ApprovalRequest> approvals = [];

  String? sessionId;
  String? provider;
  String? model;
  AutonomyLevel autonomy = AutonomyLevel.assisted;
  bool speakReplies = false;
  bool turnInProgress = false;
  String? banner;
  Usage? lastUsage;
  bool _hadConnection = false;
  String _turnText = '';

  ConnectionStatus get status => client.status;
  bool get isConnected => status == ConnectionStatus.connected;

  Future<void> restorePrefs() async {
    final p = await store.loadPrefs();
    provider = p.provider;
    model = p.model;
    autonomy = AutonomyLevel.fromName(p.autonomy);
    speakReplies = p.speakReplies;
    notifyListeners();
  }

  Future<void> connect(HubEndpoint e, {bool remember = true}) async {
    endpoint = e;
    banner = null;
    await client.connect(e);
    if (client.status == ConnectionStatus.connected && remember) {
      try {
        await store.saveConnection(
          SavedConnection(url: e.baseUrl.toString(), roomSecret: e.roomSecret),
        );
      } catch (_) {
        // Connecting must not depend on persistence; tell the user instead.
        banner =
            'Connected, but this device would not store the room secret. You will need to enter it again next time.';
      }
    } else if (client.status != ConnectionStatus.connected) {
      banner = 'Could not connect: ${client.lastError ?? 'unknown error'}';
    }
    notifyListeners();
  }

  Future<void> disconnect({bool forget = false}) async {
    await client.disconnect();
    if (forget) await store.clearConnection();
    _resetLive();
    notifyListeners();
  }

  void _onStatus(ConnectionStatus s) {
    if (s == ConnectionStatus.connected) {
      if (_hadConnection && sessionId != null) {
        // Resumed after a drop: rehydrate the transcript from the hub.
        client.send({'type': 'attachSession', 'sessionId': sessionId});
      }
      _hadConnection = true;
      banner = null;
    } else if (s == ConnectionStatus.reconnecting) {
      banner = 'Connection lost. Reconnecting…';
      turnInProgress = false;
      approvals.clear(); // approvals cannot be answered on a new socket
    } else if (s == ConnectionStatus.disconnected && _hadConnection) {
      banner = 'Disconnected: ${client.lastError ?? 'connection closed'}';
      turnInProgress = false;
      approvals.clear();
    }
    notifyListeners();
  }

  void _resetLive() {
    approvals.clear();
    turnInProgress = false;
    _hadConnection = false;
  }

  /// Applies one inbound hub message. Public so tests can drive it directly.
  void apply(HubMessage m) {
    switch (m) {
      case StatusMessage():
        break;
      case ErrorMessage(:final text, :final recoverable):
        transcript.addNotice(text, isError: !recoverable);
        if (!recoverable) {
          turnInProgress = false;
          transcript.finishTurn();
        }
      case SessionStarted(:final sessionId):
        this.sessionId = sessionId;
      case SessionHydrated(
        :final sessionId,
        :final messages,
        :final providerId,
        :final modelId,
      ):
        this.sessionId = sessionId;
        // The hub sends an (empty) hydration right after starting a session for
        // the turn we just sent; replacing the transcript then would erase the
        // user's own message. Only hydrate when no local turn is running
        // (attaching a session, or resuming after a reconnect).
        if (!turnInProgress) {
          transcript.hydrate(messages);
        }
        provider ??= providerId;
        model ??= modelId;
      case AssistantDelta(:final text):
        _turnText += text;
        transcript.appendAssistant(text);
      case ReasoningDelta(:final text):
        transcript.appendReasoning(text);
      case ToolEventMessage(:final event, :final text):
        if (event != null) transcript.upsertTool(event, fallbackText: text);
      case final ApprovalRequest r:
        if (!approvals.any((a) => a.approvalId == r.approvalId)) {
          approvals.add(r);
        }
      case ApprovalResolved(:final approvalId):
        approvals.removeWhere((a) => a.approvalId == approvalId);
      case TurnDone(:final usage):
        transcript.finishTurn();
        turnInProgress = false;
        lastUsage = usage ?? lastUsage;
        final reply = _turnText.trim();
        _turnText = '';
        if (reply.isNotEmpty) onReply?.call(reply);
      case ProvidersMessage(:final providers):
        this.providers = providers;
      case ModelsMessage(:final providerId, :final models):
        this.models[providerId] = models;
      case SessionsMessage(:final sessions):
        this.sessions = sessions;
      case HubStateMessage(:final state):
        hubState = state;
        sessions = state.sessions.isNotEmpty ? state.sessions : sessions;
      case DefaultsMessage(:final defaults):
        this.defaults = defaults;
        provider ??= defaults.provider;
        model ??= defaults.model;
      case ResetDone():
        transcript.clear();
        sessionId = null;
        turnInProgress = false;
        approvals.clear();
      case ForkDone(:final newSessionId):
        sessionId = newSessionId;
      case UnknownMessage():
        break;
    }
    notifyListeners();
  }

  // ---- intents ----------------------------------------------------------

  /// Returns null on success or a user-facing reason it was not sent.
  String? send(String prompt) {
    final text = prompt.trim();
    if (text.isEmpty) return 'Nothing to send.';
    if (!isConnected) return 'Not connected to the hub.';
    if (turnInProgress) return 'A turn is already running.';
    if (provider == null || model == null) {
      return 'Choose a provider and model in Settings first.';
    }
    _turnText = '';
    final ok = client.send({
      'type': 'send',
      'prompt': text,
      'config': autonomy.toConfig(provider: provider, model: model),
    });
    if (!ok) return 'Not connected to the hub.';
    transcript.addUser(text);
    turnInProgress = true;
    notifyListeners();
    return null;
  }

  void abort() {
    client.send({'type': 'abort'});
  }

  void respondToApproval(String approvalId, bool approved, {String? reason}) {
    client.send({
      'type': 'approval_response',
      'approvalId': approvalId,
      'approved': approved,
      'reason': ?reason,
    });
    approvals.removeWhere((a) => a.approvalId == approvalId);
    notifyListeners();
  }

  void attachSession(String id) {
    transcript.clear();
    sessionId = id;
    client.send({'type': 'attachSession', 'sessionId': id});
    notifyListeners();
  }

  void newSession() {
    client.send({'type': 'reset'});
    transcript.clear();
    sessionId = null;
    notifyListeners();
  }

  void deleteSession(String id) {
    client.send({'type': 'deleteSession', 'sessionId': id});
    if (sessionId == id) newSession();
  }

  void loadModels(String providerId) {
    if (models.containsKey(providerId)) return;
    client.send({'type': 'loadModels', 'providerId': providerId});
  }

  Future<void> select({String? provider, String? model}) async {
    if (provider != null && provider != this.provider) {
      this.provider = provider;
      this.model = models[provider]?.isNotEmpty == true
          ? models[provider]!.first.id
          : providers
                .where((p) => p.id == provider)
                .map((p) => p.defaultModelId)
                .firstOrNull;
      loadModels(provider);
    }
    if (model != null) this.model = model;
    await _persist();
    notifyListeners();
  }

  Future<void> setAutonomy(AutonomyLevel l) async {
    autonomy = l;
    await _persist();
    notifyListeners();
  }

  Future<void> setSpeakReplies(bool v) async {
    speakReplies = v;
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() => store.savePrefs(
    AppPrefs(
      provider: provider,
      model: model,
      autonomy: autonomy.name,
      speakReplies: speakReplies,
    ),
  );

  @override
  void dispose() {
    _msgSub.cancel();
    _statusSub.cancel();
    super.dispose();
  }
}
