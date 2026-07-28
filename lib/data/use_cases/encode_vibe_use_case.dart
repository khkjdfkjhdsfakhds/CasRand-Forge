import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:uuid/uuid.dart';

class VibeEncodingException implements Exception {
  final String message;
  final int? statusCode;

  const VibeEncodingException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// Calls NovelAI's official server-side V4/V4.5 Vibe extraction endpoint.
class EncodeVibeUseCase {
  static const officialEndpoint = 'https://image.novelai.net/ai/encode-vibe';
  static const timeout = Duration(seconds: 120);

  final ApiService _apiService;
  final Uuid _uuid;

  EncodeVibeUseCase({ApiService? apiService, Uuid? uuid})
      : _apiService = apiService ?? ApiService.shared,
        _uuid = uuid ?? const Uuid();

  Future<String> call({
    required Uint8List imageBytes,
    required double informationExtracted,
    required String model,
    required String token,
    required String proxy,
    String endpoint = officialEndpoint,
  }) async {
    if (imageBytes.isEmpty) {
      throw const VibeEncodingException('Vibe reference image is empty.');
    }
    if (token.isEmpty) {
      throw const VibeEncodingException(
        'A NovelAI API token is required to extract Vibe information.',
      );
    }

    // NovelAI rejects UUID-shaped values here: the image API requires
    // exactly six ASCII alphanumeric characters. A UUID's first six hex
    // digits satisfy that contract while retaining per-request randomness.
    final correlationId = _uuid.v4().replaceAll('-', '').substring(0, 6);
    late final ApiResponse response;
    try {
      response = await _apiService
          .fetchData(
            ApiRequest(
              endpoint: endpoint,
              proxy: proxy,
              headers: {
                'authorization': 'Bearer $token',
                'content-type': 'application/json',
                'referer': 'https://novelai.net',
                'x-correlation-id': correlationId,
                'x-initiated-at': DateTime.now().toUtc().toIso8601String(),
              },
              payload: {
                'image': base64Encode(imageBytes),
                'information_extracted': informationExtracted,
                'mask': null,
                'model': model,
              },
            ),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const VibeEncodingException(
        'Vibe information extraction timed out. Please retry.',
      );
    }

    final statusCode = int.tryParse(response.status) ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      throw VibeEncodingException(
        _errorMessage(response.data, statusCode),
        statusCode: statusCode,
      );
    }
    if (response.data.isEmpty) {
      throw const VibeEncodingException(
        'NovelAI returned an empty Vibe encoding.',
      );
    }
    return base64Encode(response.data);
  }

  static String endpointForDebugGenerationPath(String generationEndpoint) {
    final uri = Uri.tryParse(generationEndpoint);
    if (uri == null || uri.pathSegments.isEmpty) return generationEndpoint;
    final segments = List<String>.of(uri.pathSegments)..removeLast();
    segments.add('encode-vibe');
    return uri.replace(pathSegments: segments).toString();
  }

  static String _errorMessage(Uint8List bytes, int statusCode) {
    var serverMessage = '';
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) {
        serverMessage = decoded['message']?.toString() ?? '';
      }
    } catch (_) {
      // The image API may return non-JSON proxy/server errors.
    }
    final suffix = serverMessage.isEmpty ? '' : ': $serverMessage';
    return 'NovelAI could not extract Vibe information '
        '(HTTP $statusCode)$suffix';
  }
}
