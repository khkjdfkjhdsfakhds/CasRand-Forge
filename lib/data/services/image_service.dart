import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:gzip/gzip.dart';
import 'package:archive/archive.dart';

enum ImageMetadataEmbeddingMode {
  erased,
  stealth,
  pngInternationalText,
}

class ImageMetadataEmbeddingResult {
  final Uint8List bytes;
  final ImageMetadataEmbeddingMode mode;

  const ImageMetadataEmbeddingResult({
    required this.bytes,
    required this.mode,
  });
}

class ProcessedResponseImages extends ListBase<Uint8List> {
  final List<Uint8List> _images;
  final List<int> sampleIndices;
  final List<int> missingSampleIndices;

  ProcessedResponseImages(
    List<(int, Uint8List)> indexedImages, {
    int? expectedSampleCount,
  })  : _images = List.unmodifiable(indexedImages.map((entry) => entry.$2)),
        sampleIndices =
            List.unmodifiable(indexedImages.map((entry) => entry.$1)),
        missingSampleIndices = List.unmodifiable(
          _missingIndices(indexedImages, expectedSampleCount),
        );

  String? get incompleteWarning => missingSampleIndices.isEmpty
      ? null
      : 'NovelAI response was incomplete; missing sample '
          '${missingSampleIndices.map((index) => index + 1).join(', ')}.';

  @override
  int get length => _images.length;

  @override
  set length(int value) =>
      throw UnsupportedError('Response images are immutable.');

  @override
  Uint8List operator [](int index) => _images[index];

  @override
  void operator []=(int index, Uint8List value) =>
      throw UnsupportedError('Response images are immutable.');

  static List<int> _missingIndices(
    List<(int, Uint8List)> images,
    int? expectedSampleCount,
  ) {
    if (images.isEmpty &&
        (expectedSampleCount == null || expectedSampleCount <= 0)) {
      return const [];
    }
    final found = images.map((entry) => entry.$1).toSet();
    final observedCount = images.isEmpty ? 0 : images.last.$1 + 1;
    final sampleCount = expectedSampleCount == null
        ? observedCount
        : expectedSampleCount > observedCount
            ? expectedSampleCount
            : observedCount;
    return [
      for (var index = 0; index < sampleCount; index++)
        if (!found.contains(index)) index,
    ];
  }
}

class ImageService {
  /// Process response bytes and return image bytes
  Uint8List processResponse(Uint8List zippedResponseBytes) {
    final images = processResponseImages(zippedResponseBytes);
    final imageZero = images.sampleIndices.indexOf(0);
    if (imageZero < 0) {
      throw Exception('Image file image_0.png not found in archive.');
    }
    return images[imageZero];
  }

  /// Returns every numbered image in a NovelAI response archive, ordered by
  /// its `image_N.png` index. Remove Background returns Masked, Generated and
  /// Blend as image 0, 1 and 2 respectively.
  ProcessedResponseImages processResponseImages(
    Uint8List zippedResponseBytes, {
    int? expectedSampleCount,
  }) {
    if (!_looksLikeZip(zippedResponseBytes)) {
      final preview = _textPreview(zippedResponseBytes);
      throw Exception(
        'NovelAI returned an unexpected non-ZIP image response.'
        '${preview.isEmpty ? '' : '\nResponse data: $preview'}',
      );
    }
    try {
      final archive = ZipDecoder().decodeBytes(zippedResponseBytes);
      final indexedImages = <(int, Uint8List)>[];
      final imageName = RegExp(r'^image_(\d+)\.png$');
      for (final file in archive) {
        final match = imageName.firstMatch(file.name);
        if (match == null || !file.isFile) continue;
        final content = file.content;
        if (content is! List<int>) continue;
        final bytes =
            content is Uint8List ? content : Uint8List.fromList(content);
        if (!_looksLikePng(bytes)) continue;
        indexedImages.add((int.parse(match.group(1)!), bytes));
      }
      indexedImages.sort((a, b) => a.$1.compareTo(b.$1));
      if (indexedImages.isEmpty) {
        throw Exception('No valid numbered PNG image found in archive.');
      }
      return ProcessedResponseImages(
        indexedImages,
        expectedSampleCount: expectedSampleCount,
      );
    } catch (e) {
      throw Exception(
        'NovelAI returned an invalid or incomplete ZIP image archive: $e',
      );
    }
  }

  static bool _looksLikeZip(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      return false;
    }
    // Local file header, empty archive/EOCD, or spanned archive signature.
    return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
        (bytes[2] == 0x05 && bytes[3] == 0x06) ||
        (bytes[2] == 0x07 && bytes[3] == 0x08);
  }

  static bool _looksLikePng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static String _textPreview(Uint8List bytes) {
    if (bytes.isEmpty) return '<empty response>';
    final text = utf8.decode(bytes, allowMalformed: true).trim();
    const previewLength = 500;
    return text.length <= previewLength
        ? text
        : '${text.substring(0, previewLength)}…';
  }

  Future<Uint8List> embedMetadata(
    Uint8List imageBytes,
    String metadataString,
  ) async =>
      (await embedMetadataWithOutcome(imageBytes, metadataString)).bytes;

  Future<ImageMetadataEmbeddingResult> embedMetadataWithOutcome(
    Uint8List imageBytes,
    String metadataString,
  ) async {
    final image = img.decodePng(imageBytes);
    if (image == null) {
      throw Exception('Image decode failed while embedding metadata.');
    }
    // Re-encoding must not carry the source PNG's textual metadata forward.
    // The caller is either replacing it with custom metadata or explicitly
    // erasing metadata before the generated image is stored.
    image.textData = null;
    if (metadataString.trim().isEmpty) {
      // An erase operation should leave a genuinely clean PNG. In particular,
      // do not leave an old stealth envelope in the alpha LSBs or add an
      // empty one that can later be mistaken for a metadata channel.
      _breakStealthMetadataPrefix(image);
      return ImageMetadataEmbeddingResult(
        bytes: Uint8List.fromList(img.encodePng(image)),
        mode: ImageMetadataEmbeddingMode.erased,
      );
    }
    final zipper = GZip();
    final magicBytes = utf8.encode("stealth_pngcomp");
    final encodedData = await zipper.compress(utf8.encode(metadataString));
    final bitLength = encodedData.length * 8;
    final bitLengthInBytes = ByteData(4);
    bitLengthInBytes.setInt32(0, bitLength);
    final dataToEmbed = [
      ...magicBytes,
      ...bitLengthInBytes.buffer.asUint8List(),
      ...encodedData
    ];

    if (dataToEmbed.length * 8 > image.width * image.height) {
      return ImageMetadataEmbeddingResult(
        bytes: _encodePngWithInternationalText(image, metadataString),
        mode: ImageMetadataEmbeddingMode.pngInternationalText,
      );
    }

    var bitIndex = 0;
    for (var x = 0; x < image.width; x++) {
      for (var y = 0; y < image.height; y++) {
        final byteIndex = (bitIndex / 8).floor();
        if (byteIndex >= dataToEmbed.length) break;
        final bit = (dataToEmbed[byteIndex] >> (7 - bitIndex % 8)) & 1;
        final pixel = image.getPixel(x, y);
        // Stealth metadata uses only the alpha channel's low bit. Preserve
        // the source opacity so transparent Director Tool cutouts stay
        // transparent instead of being forced to 254/255 alpha.
        pixel.a = (pixel.a.toInt() & 0xFE) | bit;
        image.setPixel(x, y, pixel);
        bitIndex++;
      }
    }
    return ImageMetadataEmbeddingResult(
      bytes: Uint8List.fromList(img.encodePng(image)),
      mode: ImageMetadataEmbeddingMode.stealth,
    );
  }

  Future<String?> extractMetadata(img.Image image) async {
    final magicBytes = utf8.encode("stealth_pngcomp");
    final List<int> extractedBytes = [];
    int bitIndex = 0;
    int byteValue = 0;

    // 读取整个图片中的数据位
    for (var x = 0; x < image.width; x++) {
      for (var y = 0; y < image.height; y++) {
        final pixel = image.getPixel(x, y);
        final alpha = pixel.a as int;
        final bit = (alpha & 1);
        byteValue = (byteValue << 1) | bit;
        if (++bitIndex % 8 == 0) {
          extractedBytes.add(byteValue);
          byteValue = 0;
        }
      }
    }

    // 检查是否包含特定的魔法字节
    final magicByteLength = magicBytes.length;
    if (listEquals(extractedBytes.take(magicByteLength).toList(), magicBytes)) {
      // 读取数据长度
      final bitLengthBytes =
          extractedBytes.sublist(magicByteLength, magicByteLength + 4);
      final bitLength =
          ByteData.sublistView(Uint8List.fromList(bitLengthBytes)).getInt32(0);
      final dataLength = (bitLength / 8).ceil();

      // 读取实际数据并解压缩
      final compressedData = extractedBytes.sublist(
          magicByteLength + 4, magicByteLength + 4 + dataLength);
      final decompressor = GZip();
      final decodedData =
          await decompressor.decompress(Uint8List.fromList(compressedData));
      return utf8.decode(decodedData);
    }

    return null; // 如果没有找到特定的魔法字节
  }

  /// Reads generated-image metadata from either the existing PNG stealth
  /// channel, PNG tEXt/iTXt chunks, or the JPEG ExifIFD UserComment contract
  /// shared with the compression Skill.
  /// Decodes and scans image metadata outside the UI isolate.
  ///
  /// This remains the default byte-oriented API so callers cannot
  /// accidentally perform a full-image decode and alpha scan on the UI
  /// isolate.
  Future<String?> extractMetadataFromBytes(Uint8List bytes) =>
      extractMetadataFromBytesInBackground(bytes);

  /// Decodes and scans image metadata outside the UI isolate.
  Future<String?> extractMetadataFromBytesInBackground(Uint8List bytes) =>
      compute(
        _extractMetadataFromBytesInIsolate,
        bytes,
        debugLabel: 'extract-image-metadata',
      );

  /// Worker entry point for [extractMetadataFromBytesInBackground]. Do not
  /// call the public byte API here or it would recursively spawn isolates.
  static Future<String?> _extractMetadataFromBytesInIsolate(
    Uint8List bytes,
  ) async {
    try {
      if (_looksLikeJpeg(bytes)) {
        final raw = img.decodeJpgExif(bytes)?.exifIfd.userComment;
        return _validatedNovelAiUserComment(raw);
      }
      final image = img.decodeImage(bytes);
      if (image != null) {
        try {
          final stealthMetadata = await ImageService().extractMetadata(image);
          final validatedStealth = _validatedNovelAiMetadata(stealthMetadata);
          if (validatedStealth != null) return validatedStealth;
        } catch (_) {
          // A damaged optional stealth channel must not hide valid PNG text.
        }
      }
      return extractNovelAiMetadataFromPngText(bytes);
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeJpeg(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8;

  static String? _validatedNovelAiUserComment(String? raw) {
    if (raw == null) return null;
    var value = raw.replaceFirst(RegExp(r'^[\u0000\ufeff]+'), '');
    for (final prefix in const [
      'ASCII\u0000\u0000\u0000',
      'UNICODE\u0000',
      'JIS\u0000\u0000\u0000\u0000\u0000',
    ]) {
      if (value.startsWith(prefix)) {
        value = value.substring(prefix.length);
        break;
      }
    }
    return _validatedNovelAiMetadata(value);
  }

  static String? _validatedNovelAiMetadata(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    return isNovelAiGenerationMetadata(decoded) ? raw : null;
  }

  static void _breakStealthMetadataPrefix(img.Image image) {
    final magicBytes = utf8.encode('stealth_pngcomp');
    var bitIndex = 0;
    for (var x = 0; x < image.width; x++) {
      for (var y = 0; y < image.height; y++) {
        final pixel = image.getPixel(x, y);
        final alpha = pixel.a.toInt();
        final expected = (magicBytes[bitIndex ~/ 8] >> (7 - bitIndex % 8)) & 1;
        if ((alpha & 1) != expected) return;
        bitIndex++;
        if (bitIndex == magicBytes.length * 8) {
          // The first magic bit is zero. Flip just one carrier bit rather
          // than rewriting every alpha LSB, preserving ordinary PNG alpha
          // values while making an old stealth envelope unreadable.
          final first = image.getPixel(0, 0);
          first.a = first.a.toInt() & 0xfe | 1;
          image.setPixel(0, 0, first);
          return;
        }
      }
    }
  }
}

/// Reads NovelAI's outer metadata JSON from PNG `tEXt` and `iTXt` chunks.
///
/// The `image` package exposes `tEXt` inconsistently across versions and does
/// not expose `iTXt`, while NovelAI can emit either representation. This
/// parser works on the original bytes, verifies chunk CRCs, and keeps the
/// strict UTF-8/Latin-1 behavior needed for legacy `tEXt` files.
String? extractNovelAiMetadataFromPngText(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < signature.length) return null;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return null;
  }

  final textData = <String, String>{};
  var sawInvalidTextChunk = false;
  var offset = signature.length;
  while (offset + 12 <= bytes.length) {
    final length = _pngU32be(bytes, offset);
    final end = offset + 12 + length;
    if (end < offset || end > bytes.length) return null;
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    final payload = bytes.sublist(offset + 8, offset + 8 + length);
    final isTextChunk = type == 'tEXt' || type == 'iTXt';
    final crcMatches = !isTextChunk ||
        getCrc32([
              ...bytes.sublist(offset + 4, offset + 8),
              ...payload,
            ]) ==
            _pngU32be(bytes, offset + 8 + length);
    final field = switch (type) {
      'tEXt' when crcMatches => _parsePngTextChunk(payload),
      'iTXt' when crcMatches => _parsePngInternationalTextChunk(payload),
      _ => null,
    };
    if (field != null) textData[field.$1] = field.$2;
    if (isTextChunk && field == null) sawInvalidTextChunk = true;
    offset = end;
    if (type == 'IEND') break;
  }

  // A damaged Description is not evidence that the user intentionally
  // cleared it. Valid text from another carrier may still supply that field.
  if (sawInvalidTextChunk && !textData.containsKey('Description')) return null;
  return _novelAiMetadataFromPngTextData(textData);
}

/// Recognizes a generation record without confusing a cleared prompt with
/// absent metadata. Sparse records need both an explicit source and generation
/// fields; legacy prompt-bearing records retain their existing recognition.
bool isNovelAiGenerationMetadata(Map<String, dynamic> decoded) {
  try {
    final description = decoded['Description'];
    if (description != null && description is! String) return false;
    final rawComment = decoded['Comment'];
    final comment = rawComment is String ? jsonDecode(rawComment) : rawComment;
    if (comment is! Map) return false;
    final explicitNovelAi =
        decoded['Software']?.toString().toLowerCase().contains('novelai') ??
            false;
    final hasGenerationFields = const [
      'request_type',
      'steps',
      'v4_prompt',
      'sampler'
    ].any(comment.containsKey);
    final hasPrompt = description is String && description.trim().isNotEmpty;
    return hasPrompt
        ? explicitNovelAi || hasGenerationFields
        : explicitNovelAi && hasGenerationFields;
  } catch (_) {
    return false;
  }
}

String? _novelAiMetadataFromPngTextData(Map<String, String> textData) =>
    isNovelAiGenerationMetadata(textData) ? jsonEncode(textData) : null;

(String, String)? _parsePngTextChunk(List<int> payload) {
  final separator = payload.indexOf(0);
  if (separator <= 0) return null;
  final keyword = String.fromCharCodes(payload.sublist(0, separator));
  final text = _decodePngText(payload.sublist(separator + 1));
  return (keyword, text);
}

String _decodePngText(List<int> bytes) {
  try {
    // NovelAI sometimes writes UTF-8 in tEXt despite the PNG specification.
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    // Valid tEXt is ISO-8859-1; preserve that representation when the bytes
    // are not a valid UTF-8 sequence.
    return latin1.decode(bytes);
  }
}

(String, String)? _parsePngInternationalTextChunk(List<int> payload) {
  try {
    final keywordEnd = payload.indexOf(0);
    if (keywordEnd <= 0) return null;
    var offset = keywordEnd + 1;
    if (offset + 2 > payload.length) return null;

    final compressionFlag = payload[offset++];
    final compressionMethod = payload[offset++];
    if (compressionFlag > 1 || compressionMethod != 0) return null;

    final languageEnd = payload.indexOf(0, offset);
    if (languageEnd < 0) return null;
    offset = languageEnd + 1;
    final translatedKeywordEnd = payload.indexOf(0, offset);
    if (translatedKeywordEnd < 0) return null;
    offset = translatedKeywordEnd + 1;

    final textBytes = payload.sublist(offset);
    final decodedBytes = compressionFlag == 0
        ? textBytes
        : const ZLibDecoder().decodeBytes(textBytes);
    final keyword = String.fromCharCodes(payload.sublist(0, keywordEnd));
    final text = utf8.decode(decodedBytes, allowMalformed: false);
    return (keyword, text);
  } catch (_) {
    // Ignore malformed optional metadata and continue reading other chunks.
    return null;
  }
}

int _pngU32be(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

Uint8List _encodePngWithInternationalText(
  img.Image image,
  String metadataJson,
) {
  final decoded = jsonDecode(metadataJson);
  if (decoded is! Map) {
    throw const FormatException('Generated-image metadata must be a JSON map.');
  }
  final png = Uint8List.fromList(img.encodePng(image));
  final fields = <String, String>{};
  for (final entry in decoded.entries) {
    final key = entry.key.toString();
    if (key.isEmpty ||
        key.length > 79 ||
        key.codeUnits.any((unit) => unit == 0)) {
      continue;
    }
    final value = entry.value;
    fields[key] = value is String ? value : jsonEncode(value);
  }
  final chunks = fields.entries.expand(
    (entry) => _pngChunk('iTXt', [
      ...latin1.encode(entry.key),
      0,
      0,
      0,
      0,
      0,
      ...utf8.encode(entry.value),
    ]),
  );
  final iendOffset = png.length - 12;
  return Uint8List.fromList([
    ...png.sublist(0, iendOffset),
    ...chunks,
    ...png.sublist(iendOffset),
  ]);
}

List<int> _pngChunk(String type, List<int> payload) {
  final typeBytes = ascii.encode(type);
  final crc = getCrc32([...typeBytes, ...payload]);
  return [
    ..._pngU32Bytes(payload.length),
    ...typeBytes,
    ...payload,
    ..._pngU32Bytes(crc),
  ];
}

List<int> _pngU32Bytes(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
