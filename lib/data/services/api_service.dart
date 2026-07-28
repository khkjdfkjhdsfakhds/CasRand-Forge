import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';
import 'package:nai_casrand/data/models/api_request.dart';
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
  static final ApiService shared = ApiService();

  final Duration requestTimeout;
  final http.Client Function(String proxy)? _clientFactory;
  final Map<String, http.Client> _clients = {};

  ApiService({
    this.requestTimeout = defaultRequestTimeout,
    http.Client Function(String proxy)? clientFactory,
  }) : _clientFactory = clientFactory;

  Future<ApiResponse> fetchData(ApiRequest request) async {
    final url = Uri.parse(request.endpoint);
    final client = clientForProxy(request.proxy);
    http.Response response;
    try {
      final responseFuture = client.post(
        url,
        headers: request.headers,
        body: json.encode(request.payload),
      );
      response = await responseFuture.timeout(requestTimeout);
    } on TimeoutException {
      throw const NovelAiApiException(
        'NovelAI did not respond before the request timed out. '
        'Please retry later.',
        isTransient: true,
      );
    }
    return ApiResponse(
      status: response.statusCode.toString(),
      data: response.bodyBytes,
    );
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
  /// NovelAI generation, Vibe extraction and balance refreshes share this
  /// pool so sequential images can reuse established TCP/TLS connections.
  http.Client clientForProxy(String proxy) {
    final key = kIsWeb ? '' : proxy.trim();
    return _clients.putIfAbsent(
      key,
      () => _clientFactory?.call(key) ?? _createHttpClient(key),
    );
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
    return clientForProxy(proxy).get(url, headers: headers);
  }

  @visibleForTesting
  int get pooledClientCount => _clients.length;

  void close() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }
}
