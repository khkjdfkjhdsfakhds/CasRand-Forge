import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Evidence from inside the transport, before any generation request is sent.
/// An ordinary ClientException outside this boundary provides no such proof.
class GenerationRequestNotSent implements Exception {
  const GenerationRequestNotSent(this.reason, {this.retryable = false});
  final String reason;
  final bool retryable;
}

class GenerationHttpRequest extends http.Request {
  GenerationHttpRequest(super.method, super.url,
      {this.shouldSend, required this.onPhase});
  final bool Function()? shouldSend;
  final void Function(String phase) onPhase;
}

/// Keeps package:http's ordinary client for reads, while exposing the initial
/// connection boundary for generation POSTs. A redirect occurs after sending
/// and must never be classified as an initial connection failure.
class GenerationHttpClient extends http.BaseClient {
  GenerationHttpClient(this._inner) : _ordinary = IOClient(_inner);
  final HttpClient _inner;
  final IOClient _ordinary;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! GenerationHttpRequest) return _ordinary.send(request);
    if (_closed) {
      throw const GenerationRequestNotSent('client_closed', retryable: true);
    }
    final stream = request.finalize();
    request.onPhase('connecting');
    late HttpClientRequest output;
    try {
      output = await _inner.openUrl(request.method, request.url);
    } on HandshakeException {
      throw const GenerationRequestNotSent('tls_handshake');
    } on SocketException {
      throw const GenerationRequestNotSent('connection_failed',
          retryable: true);
    } on HttpException {
      throw const GenerationRequestNotSent('connection_rejected');
    }
    // Stop may have been pressed while DNS, TLS or proxy CONNECT was pending.
    if (request.shouldSend?.call() == false) {
      output.abort();
      throw const GenerationRequestNotSent('cancelled');
    }
    try {
      output
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..contentLength = request.contentLength
        ..persistentConnection = request.persistentConnection;
      request.headers.forEach((name, value) => output.headers.set(name, value));
    } catch (_) {
      output.abort();
      rethrow;
    }
    request.onPhase('sending');
    try {
      final response = await stream.pipe(output) as HttpClientResponse;
      request.onPhase('response_headers');
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.map((value) => value.trimRight()).join(',');
      });
      return http.StreamedResponse(
        response.handleError((Object error) {
          final exception = error as HttpException;
          throw http.ClientException(exception.message, exception.uri);
        }, test: (error) => error is HttpException),
        response.statusCode,
        contentLength:
            response.contentLength < 0 ? null : response.contentLength,
        request: request,
        headers: headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } on HttpException catch (error) {
      throw http.ClientException(error.message, error.uri);
    }
  }

  @override
  void close() {
    _closed = true;
    _ordinary.close();
  }
}
