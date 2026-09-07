import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:uuid/uuid.dart';

class VibeEncodingException extends NovelAiApiException {
  /// Late bytes are an encoding, not a generated-image ZIP. Keep their typed
  /// continuation separate from the generic image-response continuation.
  final Future<String>? lateEncoding;

  const VibeEncodingException(
    super.message, {
    super.statusCode,
    super.isTransient,
    super.isOutcomeUnknown,
    super.retryAfter,
    this.lateEncoding,
  });
}

/// Calls NovelAI's official server-side V4/V4.5 Vibe extraction endpoint.
class EncodeVibeUseCase {
  static const officialEndpoint = 'https://image.novelai.net/ai/encode-vibe';
  static const timeout = ApiService.defaultRequestTimeout;

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
    bool Function()? shouldSend,
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
      response = await _apiService.fetchData(
        ApiRequest(
          endpoint: endpoint,
          proxy: proxy,
          shouldSend: shouldSend,
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
      );
    } on RequestNotSentException {
      rethrow;
    } on NovelAiApiException catch (error) {
      throw _encodingError(error);
    }
    return _decodeResponse(response);
  }

  static String _decodeResponse(ApiResponse response) {
    try {
      ApiService.requireSuccessfulData(
        response,
        operation: 'extract Vibe information',
      );
    } on NovelAiApiException catch (error) {
      throw _encodingError(error);
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

  static VibeEncodingException _encodingError(NovelAiApiException error) {
    final lateEncoding = error.lateResponse?.then(_decodeResponse);
    if (lateEncoding != null) {
      unawaited(lateEncoding.then<void>((_) {}, onError: (Object _) {}));
    }
    return VibeEncodingException(
      error.message,
      statusCode: error.statusCode,
      isTransient: error.isTransient,
      isOutcomeUnknown: error.isOutcomeUnknown,
      retryAfter: error.retryAfter,
      lateEncoding: lateEncoding,
    );
  }
}
