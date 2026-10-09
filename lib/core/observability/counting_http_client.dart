/// Neural Observatory — passive network byte counting.
///
/// An `http.Client` wrapper that counts real request/response bytes of
/// traffic that was going to happen anyway (passive mode — the only mode
/// enabled by default; active transfer tests stay manual, per the spec).
/// Quality label: [MeasurementQuality.measured] for the byte counts, with
/// the caveat the UI repeats — application traffic throughput is *not* the
/// user's total internet connection speed.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

class CountingHttpClient extends http.BaseClient {
  CountingHttpClient({
    http.Client? inner,
    this.onTraffic,
  }) : _inner = inner ?? http.Client();

  final http.Client _inner;
  final void Function(int bytesOut, int bytesIn, Uri uri, DateTime at)?
      onTraffic;

  int totalBytesSent = 0;
  int totalBytesReceived = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Content-length is the honest request size for the JSON posts every
    // provider adapter makes; a streamed request without one is counted
    // as unknown-out (0), not guessed.
    final bytesOut = request.contentLength ?? 0;
    totalBytesSent += bytesOut;

    final response = await _inner.send(request);

    final declared = response.contentLength;
    if (declared != null) {
      totalBytesReceived += declared;
      onTraffic?.call(bytesOut, declared, request.url, DateTime.now());
      return response;
    }

    // Chunked/streaming response: count bytes as they actually pass.
    var received = 0;
    final controller = StreamController<List<int>>(
      onCancel: () {
        // Consumer unsubscribed early — still account for what flowed.
        totalBytesReceived += received;
      },
    );
    response.stream.listen(
      (chunk) {
        received += chunk.length;
        controller.add(chunk);
      },
      onError: controller.addError,
      onDone: () {
        totalBytesReceived += received;
        onTraffic?.call(0, received, request.url, DateTime.now());
        controller.close();
      },
    );
    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      contentLength: null,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
