import 'dart:convert';
import 'dart:typed_data';

import 'package:png_chunks_extract/png_chunks_extract.dart' as png_extract;

/// One NovelAI V4/V4.5 Vibe Transfer source.
///
/// A source can be either a normal image that still needs server-side vibe
/// extraction, or an imported NovelAI vibe file/PNG that already contains one
/// or more cached encodings. Encodings are keyed by model and Information
/// Extracted because NovelAI produces a different encoding when either changes.
class VibeConfigV4 {
  static const String expectedITXtKeyword = 'NovelAI_Vibe_Encoding_Base64';

  String fileName;
  Uint8List? imageBytes;
  double referenceStrength;
  double informationExtracted;

  final Map<String, String> _encodingCache;
  String _legacyVibeB64;

  VibeConfigV4({
    required this.fileName,
    String vibeB64 = '',
    required this.referenceStrength,
    this.informationExtracted = 0.7,
    this.imageBytes,
    Map<String, String>? encodingCache,
  })  : _legacyVibeB64 = vibeB64,
        _encodingCache = Map.of(encodingCache ?? const {});

  /// Compatibility accessor for older call sites and encoded-only fixtures.
  /// New generation code should use [encodingFor].
  String get vibeB64 => _legacyVibeB64.isNotEmpty
      ? _legacyVibeB64
      : (_encodingCache.isNotEmpty ? _encodingCache.values.first : '');

  set vibeB64(String value) => _legacyVibeB64 = value;

  bool get canEncode => imageBytes != null && imageBytes!.isNotEmpty;
  bool get hasAnyEncoding =>
      _legacyVibeB64.isNotEmpty || _encodingCache.isNotEmpty;

  String? encodingFor(
    String model, {
    double? informationExtracted,
  }) {
    final info = informationExtracted ?? this.informationExtracted;
    final exact = _encodingCache[_cacheKey(model, info)];
    if (exact != null && exact.isNotEmpty) return exact;

    // Old CasRand configs and encoded-only test fixtures did not retain model
    // metadata. They remain usable as a compatibility fallback. Image-backed
    // imports use exact cache entries and therefore correctly re-encode when
    // model or Information Extracted changes.
    if (_legacyVibeB64.isNotEmpty) return _legacyVibeB64;
    return null;
  }

  bool needsEncoding(String model) => encodingFor(model) == null;

  void cacheEncoding({
    required String model,
    required double informationExtracted,
    required String encoding,
  }) {
    if (encoding.isEmpty) {
      throw const FormatException('The Vibe encoding response was empty.');
    }
    _encodingCache[_cacheKey(model, informationExtracted)] = encoding;
  }

  Map<String, String> get encodingCache => Map.unmodifiable(_encodingCache);

  factory VibeConfigV4.fromImageBytes(
    String fileName,
    Uint8List imageBytes,
    double referenceStrength, {
    double informationExtracted = 0.7,
    String? model,
  }) {
    final config = VibeConfigV4(
      fileName: fileName,
      referenceStrength: referenceStrength.clamp(0.0, 1.0),
      informationExtracted: informationExtracted.clamp(0.0, 1.0),
      imageBytes: imageBytes,
    );

    final embeddedEncoding = _extractEmbeddedEncoding(imageBytes);
    if (embeddedEncoding != null && model != null) {
      config.cacheEncoding(
        model: model,
        informationExtracted: config.informationExtracted,
        encoding: embeddedEncoding,
      );
    } else if (embeddedEncoding != null) {
      config._legacyVibeB64 = embeddedEncoding;
    }
    return config;
  }

  /// Backwards-compatible name retained for callers that only accepted PNG.
  /// A PNG without an embedded encoding is now a valid normal image source.
  factory VibeConfigV4.fromPngBytes(
    String fileName,
    Uint8List imageBytes,
    double referenceStrength, {
    double informationExtracted = 0.7,
    String? model,
  }) {
    return VibeConfigV4.fromImageBytes(
      fileName,
      imageBytes,
      referenceStrength,
      informationExtracted: informationExtracted,
      model: model,
    );
  }

  factory VibeConfigV4.fromNaiV4VibeJson(
    String originalFileName,
    Map<String, dynamic> jsonData,
    double defaultReferenceStrength, {
    double defaultInformationExtracted = 0.7,
  }) {
    final importInfo = _asStringMap(jsonData['importInfo']);
    final importedModel = importInfo?['model']?.toString();
    final strength = _asDouble(importInfo?['strength'])?.clamp(0.0, 1.0) ??
        defaultReferenceStrength.clamp(0.0, 1.0);
    final informationExtracted =
        (_asDouble(importInfo?['information_extracted']) ??
                defaultInformationExtracted)
            .clamp(0.0, 1.0);

    Uint8List? imageBytes;
    final imageB64 = jsonData['image'];
    if (imageB64 is String && imageB64.isNotEmpty) {
      try {
        imageBytes = base64Decode(imageB64);
      } on FormatException {
        throw FormatException(
          "Invalid base64 image in '$originalFileName'.",
        );
      }
    }

    final config = VibeConfigV4(
      fileName: jsonData['name'] as String? ?? originalFileName,
      referenceStrength: strength,
      informationExtracted: informationExtracted,
      imageBytes: imageBytes,
    );

    final encodings = _asStringMap(jsonData['encodings']);
    if (encodings != null) {
      for (final modelEntry in encodings.entries) {
        final modelEncodings = _asStringMap(modelEntry.value);
        if (modelEncodings == null) continue;
        final backendModel =
            _backendModelFromExportKey(modelEntry.key) ?? importedModel;
        if (backendModel == null) continue;

        for (final encodingEntry in modelEncodings.values) {
          final encodingInfo = _asStringMap(encodingEntry);
          final encoding = encodingInfo?['encoding'];
          if (encoding is! String || encoding.isEmpty) continue;
          final params = _asStringMap(encodingInfo?['params']);
          final encodingInfoExtracted =
              (_asDouble(params?['information_extracted']) ??
                      informationExtracted)
                  .clamp(0.0, 1.0);
          config.cacheEncoding(
            model: backendModel,
            informationExtracted: encodingInfoExtracted,
            encoding: encoding,
          );
        }
      }
    }

    if (!config.hasAnyEncoding && !config.canEncode) {
      throw ArgumentError(
        "No usable image or Vibe encoding was found in '$originalFileName'.",
      );
    }
    return config;
  }

  static String _cacheKey(String model, double informationExtracted) =>
      '${_normalizeBackendModel(model)}|${informationExtracted.toStringAsFixed(6)}';

  static String _normalizeBackendModel(String model) => model.trim();

  static String? _backendModelFromExportKey(String key) {
    switch (key) {
      case 'v4full':
        return 'nai-diffusion-4-full';
      case 'v4curated':
        return 'nai-diffusion-4-curated-preview';
      case 'v4-5full':
        return 'nai-diffusion-4-5-full';
      case 'v4-5curated':
        return 'nai-diffusion-4-5-curated';
      default:
        return key.startsWith('nai-diffusion-') ? key : null;
    }
  }

  static Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  static double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static String? _extractEmbeddedEncoding(Uint8List bytes) {
    if (!_looksLikePng(bytes)) return null;
    final chunks = png_extract.extractChunks(bytes);
    for (final chunk in chunks) {
      if (chunk['name'] != 'iTXt') continue;
      final data = chunk['data'];
      if (data is! Uint8List) continue;
      final parsed = _parseITXt(data);
      if (parsed?.$1 == expectedITXtKeyword && parsed!.$2.isNotEmpty) {
        return parsed.$2;
      }
    }
    return null;
  }

  static (String, String)? _parseITXt(Uint8List data) {
    var index = data.indexOf(0);
    if (index < 0) return null;
    final keyword = utf8.decode(data.sublist(0, index), allowMalformed: true);
    index++;
    if (index + 1 >= data.length) return null;
    final compressionFlag = data[index++];
    index++; // Compression method.
    if (compressionFlag != 0) return null;

    final languageEnd = data.indexOf(0, index);
    if (languageEnd < 0) return null;
    index = languageEnd + 1;
    final translatedKeywordEnd = data.indexOf(0, index);
    if (translatedKeywordEnd < 0) return null;
    index = translatedKeywordEnd + 1;
    if (index > data.length) return null;
    return (
      keyword,
      utf8.decode(data.sublist(index), allowMalformed: true),
    );
  }

  static bool _looksLikePng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }
}
