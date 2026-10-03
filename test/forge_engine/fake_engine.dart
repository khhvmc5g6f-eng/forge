import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A fake Forge engine for tests: real HTTP + SSE on a loopback port,
/// speaking the same wire format as `gateway.ts` (`/forge/state`,
/// `/forge/events`, `/forge/health`) plus the proposed `/forge/api/v1` actions.
class FakeEngine {
  FakeEngine({this.token, this.supportsActions = false});

  /// When set, every request must carry `Authorization: Bearer <token>`.
  String? token;
  bool supportsActions;
  Map<String, dynamic> state = baseState();
  final List<String> requestLog = [];
  final List<Map<String, dynamic>> actions = [];
  final List<Map<String, String>> sseHeaders = [];
  int stateHits = 0;
  bool failState = false;
  int? stateStatus;

  HttpServer? _server;
  final List<HttpResponse> _sse = [];
  int _seq = 0;

  int get port => _server!.port;
  String get address => 'http://127.0.0.1:$port';
  int get sseClients => _sse.length;

  Future<FakeEngine> start({int port = 0}) async {
    final srv = _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    srv.listen(_handle);
    return this;
  }

  Future<void> stop() async {
    _closeStreams();
    await _server?.close(force: true);
  }

  /// Drops every open SSE connection (a network blip) while the server stays up.
  Future<void> dropStreams() async => _closeStreams();

  // Never awaited: closing a response whose client already went away can wait forever.
  void _closeStreams() {
    for (final r in List.of(_sse)) {
      r.close().then((_) {}, onError: (_) {});
    }
    _sse.clear();
  }

  /// Emits an engine event to every SSE client; returns its sequence number.
  int emit(String type, {Map<String, dynamic> data = const {}, Map<String, dynamic>? correlation, Map<String, dynamic>? target, int? seq}) {
    _seq = seq ?? _seq + 1;
    final e = {
      'seq': _seq,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'type': type,
      'data': data,
      'correlation': ?correlation,
      'target': ?target,
    };
    final frame = 'data: ${jsonEncode(e)}\n\n';
    for (final r in List.of(_sse)) {
      try {
        r.write(frame);
      } catch (_) {}
    }
    state['lastEventSeq'] = _seq;
    return _seq;
  }

  void _handle(HttpRequest req) async {
    requestLog.add('${req.method} ${req.uri.path}');
    final res = req.response;
    if (token != null && req.headers.value('authorization') != 'Bearer $token') {
      res.statusCode = 401;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'error': {'message': 'unauthorized'}}));
      await res.close();
      return;
    }
    final path = req.uri.path;
    void json(int code, Object body) {
      res.statusCode = code;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(body));
    }

    try {
      if (req.method == 'GET' && path == '/forge/state') {
        stateHits++;
        if (failState) {
          json(500, {'error': {'message': 'boom'}});
        } else if (stateStatus != null) {
          json(stateStatus!, {'error': 'x'});
        } else {
          json(200, state);
        }
      } else if (req.method == 'GET' && path == '/forge/health') {
        json(200, {'ok': true, 'keys': (state['keys'] as List).length});
      } else if (req.method == 'GET' && path == '/forge/events') {
        sseHeaders.add({'last-event-id': req.headers.value('last-event-id') ?? ''});
        res.statusCode = 200;
        res.headers.set('content-type', 'text/event-stream');
        res.headers.set('cache-control', 'no-store');
        res.bufferOutput = false;
        res.write(': open\n\n');
        await res.flush();
        _sse.add(res);
        // Hold the connection open; replies are written by emit().
        return;
      } else if (path == '/forge/api/v1/capabilities' && supportsActions) {
        json(200, {'version': '1', 'actions': ['key.add', 'key.test', 'key.update', 'key.remove', 'circuit.action', 'alert.ack', 'guard.resume']});
      } else if (path.startsWith('/forge/api/v1/') && supportsActions) {
        final body = await utf8.decoder.bind(req).join();
        actions.add({'method': req.method, 'path': path, 'body': body.isEmpty ? null : jsonDecode(body)});
        json(200, {'ok': true, 'message': 'applied'});
      } else {
        json(404, {'error': {'message': 'no route for ${req.method} $path'}});
      }
    } catch (_) {}
    await res.close();
  }

  static Map<String, dynamic> baseState({List<Map<String, dynamic>>? notifications}) => {
        'now': DateTime.now().millisecondsSinceEpoch,
        'providers': [
          {'id': 'openai', 'name': 'OpenAI', 'kind': 'cloud', 'enabled': true},
          {'id': 'ollama', 'name': 'Ollama', 'kind': 'local', 'enabled': true},
        ],
        'keys': [
          {
            'id': 'k1',
            'name': 'work',
            'providerId': 'openai',
            'masked': 'sk-…abcd',
            'enabled': true,
            'priority': 1,
            'circuit': {'id': 'openai/k1', 'level': 'key', 'state': 'closed', 'failuresInWindow': 0, 'distinctSources': 0, 'trips': 0},
            'capacity': {
              'keyId': 'k1',
              'limits': [
                {'name': 'tokensPerDay', 'used': 90, 'max': 100, 'remaining': 10, 'fraction': 0.9, 'source': 'user_configured', 'status': 'warning'}
              ],
              'worst': 'warning',
              'providerQuota': 'unknown',
              'minRemainingFraction': 0.1,
            },
            'health': {
              'keyId': 'k1',
              'score': 88.5,
              'factors': [
                {'name': 'success_rate', 'value': 0.95, 'weight': 2, 'detail': '19/20 ok'}
              ],
              'sampleSize': 20,
              'windowMs': 900000,
            },
            'last15m': {
              'calls': 20,
              'failures': 1,
              'tokens': {'input': 100, 'output': 50, 'cachedInput': 0, 'cacheWrite': 0, 'reasoning': 0, 'total': 150},
              'cost': 0.5,
              'costCurrency': 'USD',
              'estimatedRecords': 2,
            },
            'p50LatencyMs': 420,
            'p95LatencyMs': 1800,
          },
          {
            'id': 'k2',
            'name': 'spare',
            'providerId': 'openai',
            'masked': 'sk-…wxyz',
            'enabled': true,
            'priority': 2,
            'circuit': {'id': 'openai/k2', 'level': 'key', 'state': 'open', 'reason': '3 failures', 'failuresInWindow': 3, 'distinctSources': 1, 'trips': 1, 'nextProbeAt': 1},
          },
        ],
        'active': [],
        'circuits': [
          {'id': 'openai/k2', 'level': 'key', 'state': 'open', 'reason': '3 failures', 'failuresInWindow': 3, 'distinctSources': 1, 'trips': 1},
        ],
        'totals': {
          'calls': 20,
          'failures': 1,
          'tokens': {'input': 100, 'output': 50, 'cachedInput': 0, 'cacheWrite': 0, 'reasoning': 0, 'total': 150},
          'cost': 0.5,
          'costCurrency': 'USD',
          'estimatedRecords': 2,
        },
        'totalsAllTime': {
          'calls': 200,
          'failures': 5,
          'tokens': {'input': 1000, 'output': 500, 'cachedInput': 0, 'cacheWrite': 0, 'reasoning': 0, 'total': 1500},
          'cost': 0,
          'estimatedRecords': 0,
        },
        'lastEventSeq': 0,
        'guard': [
          {
            'scope': 'session:s1',
            'level': 'throttle',
            'paused': false,
            'burn': {
              'current': {'tokensPerMin': 5000, 'callsPerMin': 10, 'costPerMin': 0},
              'baseline': {'tokensPerMin': 1000, 'callsPerMin': 2, 'costPerMin': 0},
              'increasePct': {'tokens': 400}
            },
            'recentSignals': [
              {'kind': 'burn_rate', 'scope': 'session:s1', 'level': 'throttle', 'detail': 'burn 5x baseline', 'data': {}, 'ts': 1}
            ],
            'duplicateRequests': 2,
            'resentTokensEstimated': 300,
          }
        ],
        'routing': {
          'policy': 'priority',
          'ladder': {},
          'stats': {
            'decisions': 4,
            'byPolicy': {'priority': 4},
            'chosenByStep': {'preferred': 3, 'equivalent': 1},
            'rejectionReasons': {'circuit open': 2},
            'failoversUsed': 1,
          },
          'recentDecisions': [
            {
              'requestId': 'r1',
              'ts': 1,
              'policy': 'priority',
              'requestedModel': 'gpt-x',
              'candidates': [
                {
                  'target': {'providerId': 'openai', 'keyId': 'k1', 'modelId': 'gpt-x'},
                  'rank': 1,
                  'why': 'highest priority',
                  'step': 'preferred'
                }
              ],
              'rejected': [
                {'keyId': 'k2', 'modelId': 'gpt-x', 'reason': 'circuit open'}
              ],
              'chosen': {
                'target': {'providerId': 'openai', 'keyId': 'k1', 'modelId': 'gpt-x'},
                'rank': 1,
                'why': 'highest priority',
                'step': 'preferred'
              },
            }
          ],
        },
        'notifications': {'unread': notifications?.length ?? 0, 'recent': notifications ?? []},
        'diagnostics': {
          'ts': 1,
          'status': 'healthy',
          'issues': [],
          'metrics': {
            'eventLoopLagMs': {'p50': 1, 'p99': 3, 'max': 4, 'samples': 10},
            'memory': {'rssBytes': 41943040, 'heapUsedBytes': 4000000},
            'cpuPercent': 0.4,
            'inFlightRequests': 0,
          },
        },
        'analytics': {'queued': 0, 'dropped': 0, 'written': 200, 'corruptLines': 0, 'rawBytes': 1024},
        'availability': [
          {'providerId': 'openai', 'keyId': 'k1', 'keyName': 'work', 'modelId': 'gpt-x', 'status': 'available', 'checkedAt': 1, 'stale': false},
        ],
        'config': {'path': '/home/u/.forge/forge.yaml', 'present': false, 'errors': [], 'warnings': []},
      };

  static Map<String, dynamic> alert(String id, String severity, {bool ack = false}) => {
        'id': id,
        'ruleId': 'quota-95',
        'kind': 'quota',
        'severity': severity,
        'title': 'Key work at 96% of tokensPerDay',
        'message': 'work is nearly out of daily tokens',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'scope': 'k1',
        'repeats': 0,
        'acknowledged': ack,
        'data': {},
      };
}
