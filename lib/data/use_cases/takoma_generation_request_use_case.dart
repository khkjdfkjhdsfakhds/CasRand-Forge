import 'dart:convert';
import 'dart:typed_data';

import 'package:nai_casrand/data/models/api_request.dart';

/// A Takoma-bound request whose inline images were moved into its multipart
/// body.
class TakomaGenerationRequest {
  const TakomaGenerationRequest({
    required this.payload,
    required this.multipart,
  });

  /// JSON body whose image fields name the multipart parts in [multipart].
  final Map<String, dynamic> payload;

  final ApiMultipartBody multipart;
}

/// Rewrites inline base64 images as `multipart/form-data` file parts.
///
/// Takoma's relay refuses base64 image fields inside the JSON body: an img2img
/// request that carries `parameters.image` as a string answers HTTP 400
/// `E_UPSTREAM_5XX` with `image field references unknown form part`. Its own
/// client therefore posts a `request` part plus one binary part per image, and
/// each image field holds that part's name. Official NovelAI keeps the plain
/// JSON body and never reaches this converter.
class TakomaGenerationRequestUseCase {
  const TakomaGenerationRequestUseCase._();

  /// Takoma's web client caps one simultaneous fan-out batch at four images.
  static const int maxFanoutCount = 4;

  static const String requestPartName = 'request';
  static const String directorReferencePartPrefix = 'director_ref';

  /// Image fields that hold a single base64 string in the JSON body. The part
  /// name matches the field name, mirroring Takoma's own web client.
  static const List<String> singleImageFields = <String>[
    'image',
    'mask',
    'reference_image',
  ];

  /// Returns null when the request carries no inline image, so the caller can
  /// keep sending the untouched JSON body.
  static TakomaGenerationRequest? build(Map<String, dynamic> payload) {
    final parameters = payload['parameters'];
    if (parameters is Map<String, dynamic>) {
      return _buildFromParameters(payload, parameters);
    }
    if (payload['req_type'] is String) {
      return _buildFromTopLevelImage(payload);
    }
    return null;
  }

  static TakomaGenerationRequest? _buildFromParameters(
    Map<String, dynamic> payload,
    Map<String, dynamic> parameters,
  ) {
    final parts = <ApiMultipartPart>[];
    final rewritten = Map<String, dynamic>.from(parameters);

    for (final field in singleImageFields) {
      final value = parameters[field];
      if (value is! String || value.isEmpty) continue;
      final part = _imagePart(field, value);
      if (part == null) return null;
      parts.add(part);
      rewritten[field] = field;
    }

    final directorReferences = parameters['director_reference_images'];
    if (directorReferences is List && directorReferences.isNotEmpty) {
      final names = <String>[];
      for (var index = 0; index < directorReferences.length; index++) {
        final value = directorReferences[index];
        if (value is! String || value.isEmpty) return null;
        final name = '$directorReferencePartPrefix$index';
        final part = _imagePart(name, value);
        if (part == null) return null;
        parts.add(part);
        names.add(name);
      }
      rewritten['director_reference_images'] = names;
    }

    if (parts.isEmpty) return null;
    return TakomaGenerationRequest(
      payload: <String, dynamic>{...payload, 'parameters': rewritten},
      multipart: _multipart(parts, {...payload, 'parameters': rewritten}),
    );
  }

  /// Director Tools send a flat body (`req_type`, `width`, `height`, `image`)
  /// instead of a nested `parameters` map.
  static TakomaGenerationRequest? _buildFromTopLevelImage(
    Map<String, dynamic> payload,
  ) {
    final image = payload['image'];
    if (image is! String || image.isEmpty) return null;
    final part = _imagePart('image', image);
    if (part == null) return null;
    final rewritten = <String, dynamic>{...payload, 'image': 'image'};
    return TakomaGenerationRequest(
      payload: rewritten,
      multipart: _multipart(<ApiMultipartPart>[part], rewritten),
    );
  }

  static ApiMultipartBody _multipart(
    List<ApiMultipartPart> imageParts,
    Map<String, dynamic> rewrittenPayload,
  ) {
    return ApiMultipartBody(
      parts: <ApiMultipartPart>[
        ...imageParts,
        ApiMultipartPart(
          field: requestPartName,
          fileName: 'blob',
          contentType: 'application/json',
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(rewrittenPayload))),
        ),
      ],
    );
  }

  static ApiMultipartPart? _imagePart(String field, String value) {
    try {
      return ApiMultipartPart(
        field: field,
        fileName: 'blob',
        contentType: _contentTypeOf(value),
        bytes: base64Decode(_stripDataUrlPrefix(value)),
      );
    } on FormatException {
      return null;
    }
  }

  static String _stripDataUrlPrefix(String value) {
    if (!value.startsWith('data:')) return value;
    final separator = value.indexOf(',');
    return separator == -1 ? value : value.substring(separator + 1);
  }

  static String _contentTypeOf(String value) {
    if (value.startsWith('data:image/jpeg')) return 'image/jpeg';
    if (value.startsWith('data:image/webp')) return 'image/webp';
    return 'image/png';
  }
}
