import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/generation_performance_diagnostics.dart';
import 'package:nai_casrand/data/services/novelai_image_cache.dart';
import 'package:http/http.dart' as http;

class NovelAiApiException implements Exception {
  final String message;
  final int? statusCode;
  final bool isTransient;

  /// The POST was handed to the transport but its final outcome is unknown.
  /// It must not be automatically replayed without server-side deduplication.
  final bool isOutcomeUnknown;
  final Duration? retryAfter;

  /// The same in-flight request can still complete after the UI deadline.
  /// This future never submits a new request and already has an error observer.
  final Future<ApiResponse>? lateResponse;

  bool get isAccountBlocked =>
      statusCode == 401 || statusCode == 402 || statusCode == 403;
  bool get isRateLimited => statusCode == 429;

  const NovelAiApiException(
    this.message, {
    this.statusCode,
    this.isTransient = false,
    this.isOutcomeUnknown = false,
    this.retryAfter,
    this.lateResponse,
  });

  @override
  String toString() => message;
}

class RequestNotSentException extends NovelAiApiException {
  const RequestNotSentException()
      : super('The request was stopped before it was sent.');
}

class ApiService {
  static const defaultRequestTimeout = Duration(minutes: 3);
  static const maxRetryAfter = Duration(hours: 24);
  static final ApiService shared = ApiService(
    diagnosticObserver: _environmentDiagnosticObserver(),
  );

  final Duration requestTimeout;
  final http.Client Function(String proxy)? _clientFactory;
  final HttpClient Function()? _ioHttpClientFactory;
  final Map<String, http.Client> _clients = {};
  final Map<http.Client, int> _activeRequests = {};
  final Set<http.Client> _retiredClients = {};
  final NovelAiImageCache _imageCache = NovelAiImageCache();
  final GenerationPerformanceObserver? _diagnosticObserver;
  int _diagnosticSerial = 0;

  ApiService({
    this.requestTimeout = defaultRequestTimeout,
    http.Client Function(String proxy)? clientFactory,
    @visibleForTesting HttpClient Function()? ioHttpClientFactory,
    GenerationPerformanceObserver? diagnosticObserver,
  })  : _clientFactory = clientFactory,
        _ioHttpClientFactory = ioHttpClientFactory,
        _diagnosticObserver = diagnosticObserver;

  bool get diagnosticsEnabled => _diagnosticObserver != null;

  String createDiagnosticCorrelationId() {
    _diagnosticSerial++;
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '$_diagnosticSerial';
  }

  void recordDiagnostic(GenerationPerformanceEvent event) => _emit(event);

  Future<ApiResponse> fetchData(ApiRequest request) async {
    final url = Uri.parse(request.endpoint);
    final routeKey = _routeKey(request.proxy, request.headers);
    final sessionKey = '${url.origin}\u0000$routeKey';
    final usesImageCache = NovelAiImageCache.supports(url);
    final diagnosticContext = request.diagnosticContext;
    var prepared = usesImageCache
        ? await _imageCache.prepare(request.payload, sessionKey)
        : PreparedImageRequest(request.payload);
    late http.Client client;
    Future<http.Response> send(PreparedImageRequest attempt) async {
      if (request.shouldSend?.call() == false) {
        throw const RequestNotSentException();
      }
      client = _clientForRoute(request.proxy, request.headers);
      final responseFuture = _postPrepared(
        client,
        url,
        request.headers,
        attempt,
        diagnosticContext,
      );
      try {
        return await responseFuture.timeout(requestTimeout);
      } on TimeoutException {
        _emitFailure(diagnosticContext, 'outcome_unknown');
        _discardClient(routeKey, client);
        final lateResponse =
            responseFuture.then((response) => _completeResponse(
                  response,
                  sessionKey,
                  attempt,
                  diagnosticContext,
                ));
        // A caller may dismiss the card rather than await this future. Observe
        // transport errors now while preserving the future for interested UIs.
        unawaited(lateResponse.then<void>((_) {}, onError: (Object _) {}));
        throw NovelAiApiException(
          'NovelAI has not returned a complete response before the deadline. '
          'The result is unknown; retrying may consume credits again. '
          'The original request is still being received.',
          isOutcomeUnknown: true,
          lateResponse: lateResponse,
        );
      }
    }

    http.Response response;
    try {
      response = await send(prepared);
      final invalidKeys = usesImageCache ? _invalidCacheKeys(response) : null;
      if (invalidKeys != null) {
        _imageCache.invalidate(sessionKey, invalidKeys);
        prepared = await _imageCache.prepare(request.payload, sessionKey);
        response = await send(prepared);
      }
    } on http.ClientException {
      _emitFailure(diagnosticContext, 'outcome_unknown');
      _discardClient(routeKey, client);
      throw const NovelAiApiException(
        'NovelAI connection closed before a complete response was received. '
        'The result is unknown; retrying may consume credits again.',
        isOutcomeUnknown: true,
      );
    } on SocketException {
      _emitFailure(diagnosticContext, 'outcome_unknown');
      _discardClient(routeKey, client);
      throw const NovelAiApiException(
        'NovelAI connection closed before a complete response was received. '
        'The result is unknown; retrying may consume credits again.',
        isOutcomeUnknown: true,
      );
    }
    return _completeResponse(response, sessionKey, prepared, diagnosticContext);
  }

  ApiResponse _completeResponse(
    http.Response response,
    String sessionKey,
    PreparedImageRequest prepared,
    GenerationDiagnosticContext? diagnosticContext,
  ) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      _imageCache.markUploaded(sessionKey, prepared.uploadedKeys);
    }
    if (diagnosticContext != null) {
      _emit(GenerationPerformanceEvent(
        correlationId: diagnosticContext.correlationId,
        stage: response.statusCode >= 400
            ? GenerationPerformanceStage.failed
            : GenerationPerformanceStage.requestCompleted,
        statusCode: response.statusCode,
        errorClass: response.statusCode >= 400 ? 'server_response' : null,
      ));
    }
    return ApiResponse(
      status: response.statusCode.toString(),
      data: response.bodyBytes,
      headers: Map.unmodifiable(response.headers),
      receivedAt: DateTime.now().toUtc(),
    );
  }

  Future<http.Response> _postPrepared(
    http.Client client,
    Uri url,
    Map<String, String> headers,
    PreparedImageRequest prepared,
    GenerationDiagnosticContext? diagnosticContext,
  ) async {
    final body = json.encode(prepared.payload);
    final stopwatch = Stopwatch()..start();
    if (diagnosticContext != null) {
      _emit(GenerationPerformanceEvent(
        correlationId: diagnosticContext.correlationId,
        stage: GenerationPerformanceStage.cacheReady,
        requestBodyBytes: utf8.encode(body).length,
        cacheHit:
            prepared.imageSourceCount > 0 && prepared.uploadedKeys.isEmpty,
      ));
      _emit(GenerationPerformanceEvent(
        correlationId: diagnosticContext.correlationId,
        stage: GenerationPerformanceStage.requestStarted,
      ));
    }
    final request = http.Request('POST', url)
      ..headers.addAll(headers)
      ..body = body;
    _retainClient(client);
    final response = await (() async {
      final streamedResponse = await client.send(request);
      if (diagnosticContext != null) {
        _emit(GenerationPerformanceEvent(
          correlationId: diagnosticContext.correlationId,
          stage: GenerationPerformanceStage.responseStarted,
          elapsedMicroseconds: stopwatch.elapsedMicroseconds,
          statusCode: streamedResponse.statusCode,
        ));
      }
      return http.Response.fromStream(streamedResponse);
    })()
        .whenComplete(() => _releaseClient(client));
    stopwatch.stop();
    if (diagnosticContext != null) {
      _emit(GenerationPerformanceEvent(
        correlationId: diagnosticContext.correlationId,
        stage: GenerationPerformanceStage.responseCompleted,
        elapsedMicroseconds: stopwatch.elapsedMicroseconds,
        statusCode: response.statusCode,
      ));
    }
    return response;
  }

  void _emit(GenerationPerformanceEvent event) {
    try {
      _diagnosticObserver?.call(event);
    } catch (_) {
      // Diagnostics must never change generation behavior.
    }
  }

  void _emitFailure(
    GenerationDiagnosticContext? context,
    String errorClass,
  ) {
    if (context == null) return;
    _emit(GenerationPerformanceEvent(
      correlationId: context.correlationId,
      stage: GenerationPerformanceStage.failed,
      errorClass: errorClass,
    ));
  }

  Set<String>? _invalidCacheKeys(http.Response response) {
    if (response.statusCode != 400) return null;
    try {
      final body = jsonDecode(response.body);
      if (body is! Map || body['message'] != 'INVALID_CACHE_KEYS') return null;
      final details = body['details'];
      if (details is! Map || details['invalidKeys'] is! List) return null;
      return (details['invalidKeys'] as List)
          .whereType<String>()
          .where((key) => key.isNotEmpty)
          .toSet();
    } on FormatException {
      return null;
    }
  }

  /// Returns the response body for a successful request, or throws a readable
  /// API error before binary image post-processing gets a chance to interpret
  /// a JSON/HTML error response as a ZIP archive.
  static Uint8List requireSuccessfulData(
    ApiResponse response, {
    String operation = 'complete the request',
  }) {
    final statusCode = int.tryParse(response.status) ?? 0;
    if (statusCode >= 200 && statusCode < 300) return response.data;

    final serverMessage = _serverMessage(response.data);
    final lowerMessage = serverMessage.toLowerCase();
    final serverTimedOut =
        lowerMessage.contains('timeout') || lowerMessage.contains('timed out');
    // A timeout generated by an intermediary is not evidence that the paid
    // operation stopped on the origin. Keep it separate from explicit errors.
    final isOutcomeUnknown = statusCode == 408 ||
        statusCode == 504 ||
        (statusCode >= 500 && serverTimedOut);
    final isTransient = !isOutcomeUnknown &&
        (statusCode == 425 || statusCode == 429 || statusCode >= 500);

    final summary = statusCode >= 500 && serverTimedOut
        ? 'NovelAI server timed out while trying to $operation '
            '(HTTP $statusCode).'
        : 'NovelAI could not $operation (HTTP $statusCode).';
    final detail =
        serverMessage.isEmpty ? '' : '\nServer message: $serverMessage';
    throw NovelAiApiException(
      '$summary$detail${isOutcomeUnknown ? '\nThe result is unknown; retrying may consume credits again.' : ''}',
      statusCode: statusCode == 0 ? null : statusCode,
      isTransient: isTransient,
      isOutcomeUnknown: isOutcomeUnknown,
      retryAfter: _retryAfter(response),
    );
  }

  static Duration? _retryAfter(ApiResponse response) {
    final value = response.headers.entries
        .where((entry) => entry.key.toLowerCase() == 'retry-after')
        .map((entry) => entry.value.trim())
        .firstOrNull;
    if (value == null || value.isEmpty) return null;
    Duration duration;
    if (RegExp(r'^\d+$').hasMatch(value)) {
      // Parse only after bounding the text to avoid integer/microsecond
      // overflow from malformed or unreasonably distant server suggestions.
      final seconds = int.tryParse(value);
      if (seconds == null || seconds > maxRetryAfter.inSeconds) {
        return maxRetryAfter;
      }
      duration = Duration(seconds: seconds);
    } else {
      try {
        final date = HttpDate.parse(value);
        duration = date.difference(response.receivedAt ?? DateTime.now());
      } on FormatException {
        return null;
      } on HttpException {
        return null;
      }
    }
    if (duration.isNegative) return Duration.zero;
    return duration > maxRetryAfter ? maxRetryAfter : duration;
  }

  static String _serverMessage(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final message = decoded['message']?.toString().trim() ?? '';
        if (message.isNotEmpty) return message;
        final error = decoded['error']?.toString().trim() ?? '';
        if (error.isNotEmpty) return error;
      }
    } catch (_) {
      // Proxies and upstream gateways may return plain text or HTML instead.
    }
    const previewLength = 500;
    return text.length <= previewLength
        ? text
        : '${text.substring(0, previewLength)}…';
  }

  /// Returns a persistent client for the selected proxy route.
  ///
  /// Requests without credentials share this proxy route. Authenticated
  /// requests are isolated by credential in [_clientForRoute] so one account
  /// never reuses another account's persistent NovelAI connection.
  http.Client clientForProxy(String proxy) {
    return _clientForRoute(proxy, const {});
  }

  http.Client _clientForRoute(
    String proxy,
    Map<String, String> headers,
  ) {
    final key = kIsWeb ? '' : proxy.trim();
    final routeKey = _routeKey(proxy, headers);
    return _clients.putIfAbsent(
      routeKey,
      () => _clientFactory?.call(key) ?? _createHttpClient(key),
    );
  }

  String _routeKey(
    String proxy,
    Map<String, String> headers,
  ) {
    final key = kIsWeb ? '' : proxy.trim();
    final authorization = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'authorization')
        .map((entry) => entry.value.trim())
        .firstOrNull;
    return '$key\u0000${authorization ?? ''}';
  }

  void _discardClient(String routeKey, http.Client failedClient) {
    if (!identical(_clients[routeKey], failedClient)) return;
    _clients.remove(routeKey);
    _retireClient(failedClient);
  }

  void _retainClient(http.Client client) {
    _activeRequests[client] = (_activeRequests[client] ?? 0) + 1;
  }

  void _releaseClient(http.Client client) {
    final remaining = (_activeRequests[client] ?? 1) - 1;
    if (remaining > 0) {
      _activeRequests[client] = remaining;
      return;
    }
    _activeRequests.remove(client);
    if (_retiredClients.remove(client)) client.close();
  }

  void _retireClient(http.Client client) {
    if ((_activeRequests[client] ?? 0) > 0) {
      _retiredClients.add(client);
    } else {
      client.close();
    }
  }

  http.Client _createHttpClient(String proxy) {
    if (kIsWeb) return http.Client();
    final ioClient = _ioHttpClientFactory?.call() ?? HttpClient();
    ioClient.connectionTimeout = const Duration(seconds: 15);
    ioClient.idleTimeout = const Duration(minutes: 2);
    ioClient.maxConnectionsPerHost = 6;
    if (proxy.isNotEmpty) {
      ioClient.findProxy = (uri) => 'PROXY $proxy';
    }
    return IOClient(ioClient);
  }

  Future<http.Response> get(
    Uri url, {
    required String proxy,
    Map<String, String>? headers,
  }) {
    final client = _clientForRoute(proxy, headers ?? const {});
    _retainClient(client);
    return client
        .get(url, headers: headers)
        .whenComplete(() => _releaseClient(client));
  }

  @visibleForTesting
  int get pooledClientCount => _clients.length;

  @visibleForTesting
  int get pooledImageCacheSessionCount => _imageCache.sessionCount;

  /// Closes pooled connections whose proxy route or authorization credential
  /// is no longer valid. New requests recreate only the connections they need.
  void invalidateRoutes({String? token, String? proxy}) {
    final normalizedProxy = proxy?.trim();
    final clientsToClose = <http.Client>[];
    _clients.removeWhere((routeKey, client) {
      final matches = _routeMatches(
        routeKey,
        token: token,
        normalizedProxy: normalizedProxy,
      );
      if (matches) clientsToClose.add(client);
      return matches;
    });
    _imageCache.removeSessionsWhere((sessionKey) {
      final originSeparator = sessionKey.indexOf('\u0000');
      final routeKey = originSeparator < 0
          ? sessionKey
          : sessionKey.substring(originSeparator + 1);
      return _routeMatches(
        routeKey,
        token: token,
        normalizedProxy: normalizedProxy,
      );
    });
    for (final client in clientsToClose) {
      _retireClient(client);
    }
  }

  bool _routeMatches(
    String routeKey, {
    required String? token,
    required String? normalizedProxy,
  }) {
    final separator = routeKey.indexOf('\u0000');
    final routeProxy =
        separator < 0 ? routeKey : routeKey.substring(0, separator);
    final authorization =
        separator < 0 ? '' : routeKey.substring(separator + 1);
    final tokenMatches = token == null ||
        authorization == token ||
        authorization == 'Bearer $token';
    final proxyMatches =
        normalizedProxy == null || routeProxy == normalizedProxy;
    return tokenMatches && proxyMatches;
  }

  void close() {
    for (final client in {..._clients.values, ..._retiredClients}) {
      client.close();
    }
    _clients.clear();
    _retiredClients.clear();
    _imageCache.clear();
  }
}

GenerationPerformanceObserver? _environmentDiagnosticObserver() {
  if (Platform.environment['CASRAND_PERFORMANCE_DIAGNOSTICS'] != '1') {
    return null;
  }
  return (event) {
    debugPrint('casrand_generation_performance ${jsonEncode(event.toJson())}');
  };
}
