import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'engine_client.dart';
import 'engine_credentials.dart';
import 'engine_endpoint.dart';
import 'engine_models.dart';

enum EngineLinkStatus {
  /// No engine address has been entered yet.
  unconfigured,

  /// First attempt in progress.
  connecting,

  /// The last state poll succeeded.
  connected,

  /// The engine is not answering; retrying with backoff. [EngineConnection.state] (if any) is stale.
  reconnecting,

  /// The engine answered 401/403. Retrying will not help until the token changes.
  unauthorized,

  /// The user disconnected on purpose.
  disconnected,
}

typedef EngineClientFactory = EngineClient Function(EngineEndpoint endpoint, String? token);
typedef EngineDelay = Future<void> Function(Duration d);

/// Exponential backoff with a cap: 1s, 2s, 4s, ... 30s.
Duration defaultEngineBackoff(int attempt) {
  final secs = math.min(30, math.pow(2, math.max(0, attempt - 1)).toInt());
  return Duration(seconds: secs);
}

/// Owns the link to one Forge engine: state polling, the SSE event feed,
/// reconnect with backoff, honest status. Everything the UI shows about the
/// engine comes through here; nothing is cached across restarts except the
/// address and token (see [EngineCredentialStore]).
class EngineConnection extends ChangeNotifier {
  EngineConnection({
    EngineClientFactory? clientFactory,
    this.credentials,
    this.pollInterval = const Duration(seconds: 5),
    this.pollIntervalWithoutStream = const Duration(seconds: 2),
    this.minRefreshGap = const Duration(milliseconds: 1500),
    EngineDelay? delay,
    this.backoff = defaultEngineBackoff,
    DateTime Function()? clock,
    this.maxEvents = 500,
  })  : _clientFactory = clientFactory ?? ((e, t) => EngineClient(endpoint: e, token: t)),
        _delay = delay ?? ((d) => Future<void>.delayed(d)),
        _clock = clock ?? DateTime.now;

  final EngineClientFactory _clientFactory;
  final EngineCredentialStore? credentials;
  final Duration pollInterval, pollIntervalWithoutStream, minRefreshGap;
  final Duration Function(int attempt) backoff;
  final EngineDelay _delay;
  final DateTime Function() _clock;
  final int maxEvents;

  // ---- observable state ----
  EngineLinkStatus status = EngineLinkStatus.unconfigured;
  EngineEndpoint? endpoint;
  String? error;
  EngineState? state;

  /// When [state] was fetched. Null until the first successful poll.
  DateTime? lastStateAt;
  EngineCapabilities capabilities = EngineCapabilities.none;

  /// True once capabilities were actually asked of the engine (not just defaulted).
  bool capabilitiesKnown = false;

  /// The SSE feed is open right now.
  bool eventsLive = false;

  /// Events missed while the feed was down (engine replay buffer overflowed).
  int missedEvents = 0;
  int retryAttempt = 0;
  DateTime? nextRetryAt;

  /// True when the token could not be written to the secure store.
  bool tokenNotPersisted = false;
  final List<EngineEvent> events = [];

  final _eventCtl = StreamController<EngineEvent>.broadcast();
  final _criticalCtl = StreamController<EngineNotification>.broadcast();

  /// Every real event, as it arrives. Live Flow and the network view listen here.
  Stream<EngineEvent> get eventStream => _eventCtl.stream;

  /// New critical alerts that appeared while connected (not those that were already there on connect).
  Stream<EngineNotification> get criticalAlerts => _criticalCtl.stream;

  String? _token;
  EngineClient? _client;
  int _gen = 0;
  int _lastSeq = 0;
  bool _refreshing = false;
  DateTime? _lastRefresh;
  Set<String>? _seenAlerts;
  bool _disposed = false;

  bool get isConnected => status == EngineLinkStatus.connected;
  bool get hasToken => _token != null && _token!.isNotEmpty;

  /// True when [state] is older than the staleness horizon or we are not connected.
  bool get isStale {
    if (state == null) return false;
    if (status != EngineLinkStatus.connected) return true;
    final at = lastStateAt;
    return at != null && _clock().difference(at) > pollInterval * 3;
  }

  // ----------------------------------------------------------- control ----

  /// Loads the saved engine (if any) and connects.
  Future<void> restore() async {
    final saved = await credentials?.load();
    if (saved == null) return;
    await configure(saved.endpoint, token: saved.token, persist: false);
  }

  /// Sets the engine to talk to and connects. [persist] stores the address and
  /// token (token in the secure store only).
  Future<void> configure(EngineEndpoint e, {String? token, bool persist = true}) async {
    _stopLoops();
    endpoint = e;
    _token = token;
    state = null;
    lastStateAt = null;
    events.clear();
    _lastSeq = 0;
    _seenAlerts = null;
    missedEvents = 0;
    capabilities = EngineCapabilities.none;
    capabilitiesKnown = false;
    if (persist && credentials != null) {
      tokenNotPersisted = !(await credentials!.save(e, token));
    }
    await connect();
  }

  Future<void> connect() async {
    final e = endpoint;
    if (e == null) {
      status = EngineLinkStatus.unconfigured;
      _notify();
      return;
    }
    _stopLoops();
    final gen = _gen;
    _client = _clientFactory(e, _token);
    status = EngineLinkStatus.connecting;
    error = null;
    retryAttempt = 0;
    nextRetryAt = null;
    _notify();
    unawaited(_pollLoop(gen));
  }

  Future<void> disconnect() async {
    _stopLoops();
    status = endpoint == null ? EngineLinkStatus.unconfigured : EngineLinkStatus.disconnected;
    _notify();
  }

  /// Forget the engine: address, token, and every cached value.
  Future<void> forget() async {
    _stopLoops();
    await credentials?.clear();
    endpoint = null;
    _token = null;
    state = null;
    lastStateAt = null;
    events.clear();
    status = EngineLinkStatus.unconfigured;
    error = null;
    _notify();
  }

  /// One-off refresh (pull-to-refresh, after an action).
  Future<void> refresh() => _refreshNow(force: true);

  /// The client for actions. Null when not configured.
  EngineClient? get client => _client;

  void _stopLoops() {
    _gen++;
    _client?.close();
    _client = null;
    eventsLive = false;
  }

  // -------------------------------------------------------------- loops ----

  Future<void> _pollLoop(int gen) async {
    var sseStarted = false;
    while (gen == _gen && !_disposed) {
      final client = _client;
      if (client == null) return;
      try {
        final s = await client.fetchState();
        if (gen != _gen) return;
        _applyState(s);
        retryAttempt = 0;
        nextRetryAt = null;
        error = null;
        status = EngineLinkStatus.connected;
        _notify();
        if (!capabilitiesKnown) unawaited(_loadCapabilities(gen, client));
        if (!sseStarted) {
          sseStarted = true;
          unawaited(_sseLoop(gen));
        }
        await _delay(eventsLive ? pollInterval : pollIntervalWithoutStream);
      } on EngineException catch (e) {
        if (gen != _gen) return;
        error = e.message;
        if (e.kind == EngineErrorKind.unauthorized) {
          status = EngineLinkStatus.unauthorized;
          eventsLive = false;
          _notify();
          return;
        }
        retryAttempt++;
        final wait = backoff(retryAttempt);
        nextRetryAt = _clock().add(wait);
        status = EngineLinkStatus.reconnecting;
        eventsLive = false;
        _notify();
        await _delay(wait);
      } catch (e) {
        if (gen != _gen) return;
        error = 'Unexpected error: $e';
        retryAttempt++;
        final wait = backoff(retryAttempt);
        nextRetryAt = _clock().add(wait);
        status = EngineLinkStatus.reconnecting;
        _notify();
        await _delay(wait);
      }
    }
  }

  Future<void> _loadCapabilities(int gen, EngineClient client) async {
    try {
      final c = await client.capabilities();
      if (gen != _gen) return;
      capabilities = c;
      capabilitiesKnown = true;
      _notify();
    } on EngineException {
      // Leave unknown; retried after the next reconnect.
    }
  }

  Future<void> _sseLoop(int gen) async {
    var attempt = 0;
    while (gen == _gen && !_disposed) {
      final client = _client;
      if (client == null) return;
      try {
        final first = _lastSeq == 0;
        var sawFirstAfterOpen = false;
        await for (final e in client.events(
          afterSeq: _lastSeq,
          onOpen: () {
            if (gen != _gen) return;
            eventsLive = true;
            attempt = 0;
            _notify();
          },
        )) {
          if (gen != _gen) return;
          if (e.seq <= _lastSeq) continue;
          if (!sawFirstAfterOpen) {
            sawFirstAfterOpen = true;
            if (!first && e.seq > _lastSeq + 1) {
              missedEvents += e.seq - _lastSeq - 1;
            }
          }
          _lastSeq = e.seq;
          events.add(e);
          if (events.length > maxEvents) events.removeRange(0, events.length - maxEvents);
          if (!_eventCtl.isClosed) _eventCtl.add(e);
          if (engineStateChangingEvents.contains(e.type)) unawaited(_refreshNow());
          _notify();
        }
        // The server closed the stream cleanly.
        if (gen != _gen) return;
        eventsLive = false;
        _notify();
      } on EngineException catch (e) {
        if (gen != _gen) return;
        eventsLive = false;
        if (e.kind == EngineErrorKind.unauthorized) {
          _notify();
          return;
        }
        _notify();
      } catch (_) {
        if (gen != _gen) return;
        eventsLive = false;
        _notify();
      }
      attempt++;
      await _delay(backoff(attempt));
    }
  }

  Future<void> _refreshNow({bool force = false}) async {
    final client = _client;
    if (client == null || _refreshing) return;
    final last = _lastRefresh;
    if (!force && last != null && _clock().difference(last) < minRefreshGap) return;
    _refreshing = true;
    final gen = _gen;
    try {
      final s = await client.fetchState();
      if (gen != _gen) return;
      _applyState(s);
      if (status != EngineLinkStatus.connected) {
        status = EngineLinkStatus.connected;
        error = null;
        retryAttempt = 0;
      }
      _notify();
    } on EngineException catch (e) {
      // The poll loop owns status transitions; just remember why this failed.
      if (gen == _gen) error = e.message;
    } finally {
      _lastRefresh = _clock();
      _refreshing = false;
    }
  }

  void _applyState(EngineState s) {
    // The engine restarted: its sequence numbers start again from 1.
    if (_lastSeq > 0 && s.lastEventSeq < _lastSeq) {
      _lastSeq = 0;
      events.clear();
      missedEvents = 0;
    }
    state = s;
    lastStateAt = _clock();
    final ids = s.notifications.map((n) => n.id).toSet();
    final seen = _seenAlerts;
    if (seen == null) {
      _seenAlerts = ids;
    } else {
      for (final n in s.notifications) {
        if (!seen.contains(n.id)) {
          seen.add(n.id);
          if (n.isCritical && !n.acknowledged && !_criticalCtl.isClosed) _criticalCtl.add(n);
        }
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ----------------------------------------------------------- actions ----

  /// Runs an engine action, then refreshes state so the UI reflects the result.
  /// Throws [EngineException] (including `notSupported` on a read-only engine).
  Future<EngineActionResult> run(Future<EngineActionResult> Function(EngineClient c) action) async {
    final c = _client;
    if (c == null) throw EngineException(EngineErrorKind.unreachable, 'Not connected to an engine.');
    final r = await action(c);
    await _refreshNow(force: true);
    return r;
  }

  // ---- test hooks (widget tests drive the UI without a network) ----

  /// Sets observable state directly, as if a poll had just succeeded.
  @visibleForTesting
  void debugApply({EngineState? state, EngineLinkStatus? status, EngineEndpoint? endpoint, EngineCapabilities? capabilities, bool? eventsLive, String? error}) {
    if (endpoint != null) this.endpoint = endpoint;
    if (state != null) {
      _applyState(state);
      this.state = state;
    }
    if (status != null) this.status = status;
    if (capabilities != null) {
      this.capabilities = capabilities;
      capabilitiesKnown = true;
    }
    if (eventsLive != null) this.eventsLive = eventsLive;
    if (error != null) this.error = error;
    _notify();
  }

  /// Delivers an event as if it had arrived on the SSE stream.
  @visibleForTesting
  void debugEmit(EngineEvent e) {
    _lastSeq = e.seq;
    events.add(e);
    if (!_eventCtl.isClosed) _eventCtl.add(e);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopLoops();
    _eventCtl.close();
    _criticalCtl.close();
    super.dispose();
  }
}
