import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:gzip/gzip.dart';
import 'package:archive/archive.dart';

class ImageService {
  /// Process response bytes and return image bytes
  Uint8List processResponse(Uint8List zippedResponseBytes) {
    return processResponseImages(zippedResponseBytes).first;
  }

  /// Returns every numbered image in a NovelAI response archive, ordered by
  /// its `image_N.png` index. Remove Background returns Masked, Generated and
  /// Blend as image 0, 1 and 2 respectively.
  List<Uint8List> processResponseImages(Uint8List zippedResponseBytes) {
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
        indexedImages.add((
          int.parse(match.group(1)!),
          content is Uint8List ? content : Uint8List.fromList(content),
        ));
      }
      indexedImages.sort((a, b) => a.$1.compareTo(b.$1));
      if (indexedImages.isEmpty || indexedImages.first.$1 != 0) {
        throw Exception('Image file image_0.png not found in archive.');
      }
      return indexedImages.map((entry) => entry.$2).toList(growable: false);
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
  ) async {
    final image = img.decodePng(imageBytes);
    if (image == null) {
      throw Exception('Image decode failed while embedding metadata.');
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
    return img.encodePng(image);
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
  /// channel or the JPEG ExifIFD UserComment contract shared with the
  /// compression Skill.
  Future<String?> extractMetadataFromBytes(Uint8List bytes) async {
    try {
      if (_looksLikeJpeg(bytes)) {
        final raw = img.decodeJpgExif(bytes)?.exifIfd.userComment;
        return _validatedNovelAiUserComment(raw);
      }
      final image = img.decodeImage(bytes);
      if (image == null) return null;
      return extractMetadata(image);
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
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) return null;
    final description = decoded['Description'];
    final rawComment = decoded['Comment'];
    if (description is! String || rawComment == null) return null;
    final Object? comment =
        rawComment is String ? jsonDecode(rawComment) : rawComment;
    if (comment is! Map) return null;
    final software = decoded['Software']?.toString().toLowerCase() ?? '';
    final looksNovelAi = software.contains('novelai') ||
        const ['request_type', 'steps', 'v4_prompt', 'sampler']
            .any(comment.containsKey);
    return looksNovelAi ? value : null;
  }
}
