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

  const NovelAiApiException(
    this.message, {
    this.statusCode,
    this.isTransient = false,
  });

  @override
  String toString() => message;
}

class ApiService {
  static const defaultRequestTimeout = Duration(minutes: 3);
  static final ApiService shared = ApiService(
    diagnosticObserver: _environmentDiagnosticObserver(),
  );

  final Duration requestTimeout;
  final http.Client Function(String proxy)? _clientFactory;
  final Map<String, http.Client> _clients = {};
  final NovelAiImageCache _imageCache = NovelAiImageCache();
  final GenerationPerformanceObserver? _diagnosticObserver;
  int _diagnosticSerial = 0;

  ApiService({
    this.requestTimeout = defaultRequestTimeout,
    http.Client Function(String proxy)? clientFactory,
    GenerationPerformanceObserver? diagnosticObserver,
  })  : _clientFactory = clientFactory,
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
    final client = _clientForRoute(request.proxy, request.headers);
    final sessionKey = '${url.origin}\u0000$routeKey';
    final usesImageCache = NovelAiImageCache.supports(url);
    final diagnosticContext = request.diagnosticContext;
    var prepared = usesImageCache
        ? await _imageCache.prepare(request.payload, sessionKey)
        : PreparedImageRequest(request.payload);
    http.Response response;
    try {
      response = await _postPrepared(
        client,
        url,
        request.headers,
        prepared,
        diagnosticContext,
      );
      final invalidKeys = usesImageCache ? _invalidCacheKeys(response) : null;
      if (invalidKeys != null) {
        _imageCache.invalidate(sessionKey, invalidKeys);
        prepared = await _imageCache.prepare(request.payload, sessionKey);
        response = await _postPrepared(
          client,
          url,
          request.headers,
          prepared,
          diagnosticContext,
        );
      }
    } on TimeoutException {
      _emitFailure(diagnosticContext, 'client_timeout');
      _discardClient(routeKey, client);
      throw const NovelAiApiException(
        'NovelAI did not respond before the request timed out. '
        'The next automatic attempt will use a fresh connection.',
        isTransient: true,
      );
    } on http.ClientException {
      _emitFailure(diagnosticContext, 'connection_closed');
      _discardClient(routeKey, client);
      throw const NovelAiApiException(
        'NovelAI connection closed before a complete response was received. '
        'The next automatic attempt will use a fresh connection.',
        isTransient: true,
      );
    } on SocketException {
      _emitFailure(diagnosticContext, 'connection_closed');
      _discardClient(routeKey, client);
      throw const NovelAiApiException(
        'NovelAI connection closed before a complete response was received. '
        'The next automatic attempt will use a fresh connection.',
        isTransient: true,
      );
    }
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
        .timeout(requestTimeout);
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
    final isTransient = statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500;

    final summary = statusCode >= 500 && serverTimedOut
        ? 'NovelAI server timed out while trying to $operation '
            '(HTTP $statusCode). Please retry later.'
        : 'NovelAI could not $operation (HTTP $statusCode).';
    final detail =
        serverMessage.isEmpty ? '' : '\nServer message: $serverMessage';
    throw NovelAiApiException(
      '$summary$detail',
      statusCode: statusCode == 0 ? null : statusCode,
      isTransient: isTransient,
    );
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
    failedClient.close();
  }

  http.Client _createHttpClient(String proxy) {
    if (kIsWeb || proxy.isEmpty) return http.Client();
    final ioClient = HttpClient();
    ioClient.connectionTimeout = const Duration(seconds: 15);
    ioClient.idleTimeout = const Duration(minutes: 2);
    ioClient.maxConnectionsPerHost = 6;
    ioClient.findProxy = (uri) => 'PROXY $proxy';
    ioClient.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
    return IOClient(ioClient);
  }

  Future<http.Response> get(
    Uri url, {
    required String proxy,
    Map<String, String>? headers,
  }) {
    return _clientForRoute(proxy, headers ?? const {}).get(
      url,
      headers: headers,
    );
  }

  @visibleForTesting
  int get pooledClientCount => _clients.length;

  void close() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
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
