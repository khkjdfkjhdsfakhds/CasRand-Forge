import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gzip/gzip.dart';
import 'package:image/image.dart' as img;

import 'package:nai_casrand/data/services/generated_image_jpeg_encoder.dart';
import 'package:nai_casrand/data/services/image_service.dart';

void main() {
  group('GeneratedImageJpegEncoder', () {
    test('encodes opaque PNG at the fixed Q92 4:4:4 settings', () async {
      final png = _opaquePng(width: 64, height: 48);

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded);
      expect(result.jpegBytes, isNotNull);
      expect(result.width, 64);
      expect(result.height, 48);
      expect(result.hasTransparency, isFalse);
      expect(result.jpegBytes, _hasSof444AndDimensions(64, 48));
      expect(result.jpegBytes, _hasQuality92LumaQuantization());
    });

    test('round-trips the complete compact ASCII NovelAI metadata bundle',
        () async {
      const metadata = <String, Object?>{
        'Description': 'a café ✨',
        'Software': 'NovelAI',
        'Source': 'Stable Diffusion XL',
        'Generation time': '1.25',
        'Title': 'fixture',
        'Comment': '{"prompt":"café","steps":28,"width":19}',
      };
      final png = await ImageService().embedMetadata(
        _opaquePng(width: 64, height: 48),
        jsonEncode(metadata),
      );

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded);
      expect(result.metadataJson, isNotNull);
      expect(result.metadataJson, contains(r'\u00e9'));
      expect(result.metadataJson, contains(r'\u2728'));
      expect(result.metadataJson, isNot(contains(' café ')));

      final jpeg = result.jpegBytes!;
      final reopened = img.decodeJpg(jpeg);
      final exif = img.decodeJpgExif(jpeg);
      expect(reopened, isNotNull);
      expect(reopened!.width, 64);
      expect(reopened.height, 48);
      expect(exif, isNotNull);
      expect(
        exif!.exifIfd.userComment,
        'ASCII\u0000\u0000\u0000${result.metadataJson}',
      );
      expect(exif.imageIfd.imageDescription, r'a caf\u00e9 \u2728');
      expect(exif.imageIfd.software, 'NovelAI');
    });

    test('reads the NovelAI PNG tEXt Comment when no stealth channel exists',
        () async {
      final image = img.Image(width: 64, height: 48, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(80, 120, 160, 255));
      image.addTextData({
        'Title': 'AI generated image',
        'Description': 'fixture prompt',
        'Software': 'NovelAI',
        'Source': 'NovelAI Diffusion V5 0ADF9AB7',
        'Comment': '{"prompt":"fixture prompt","steps":28}',
      });

      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        Uint8List.fromList(img.encodePng(image)),
      );
      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, contains('fixture prompt'));
      final extracted = await ImageService().extractMetadataFromBytes(
        result.jpegBytes!,
      );
      expect(extracted, isNotNull);
      expect(jsonDecode(extracted!)['Comment'],
          '{"prompt":"fixture prompt","steps":28}');
    });

    test('preserves Latin-1 tEXt instead of replacing non-UTF-8 bytes',
        () async {
      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        _pngWithNovelAiLatin1Text(),
      );

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, contains(r'caf\u00e9 prompt'));
      expect(result.metadataJson, isNot(contains(r'caf\ufffd prompt')));
    });

    test('reads NovelAI metadata stored in uncompressed iTXt chunks', () async {
      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        _pngWithNovelAiITXt(compressed: false),
      );

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, isNotNull);
      expect(result.metadataJson, contains('itxt prompt'));
      expect(result.metadataJson, contains('itxt negative'));
      expect(
        img.decodeJpgExif(result.jpegBytes!)?.exifIfd.userComment,
        'ASCII\u0000\u0000\u0000${result.metadataJson}',
      );
    });

    test('reads NovelAI metadata stored in zlib-compressed iTXt chunks',
        () async {
      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        _pngWithNovelAiITXt(compressed: true),
      );

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, isNotNull);
      expect(result.metadataJson, contains('itxt prompt'));
      expect(result.metadataJson, contains('itxt negative'));
      expect(
        await ImageService().extractMetadataFromBytes(result.jpegBytes!),
        result.metadataJson,
      );
    });

    test('skips malformed iTXt while preserving valid tEXt metadata', () async {
      final png = _opaquePngWithTextData();
      final malformed = _pngITXtChunk(
        'Description',
        'ignored',
        compressed: false,
        compressionFlagOverride: 2,
      );
      final iendOffset = png.length - 12;
      final mixedPng = Uint8List.fromList([
        ...png.sublist(0, iendOffset),
        ...malformed,
        ...png.sublist(iendOffset),
      ]);

      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        mixedPng,
      );

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, contains('fixture prompt'));
    });

    test('ignores text chunks with an invalid PNG CRC', () async {
      final png = _opaquePngWithTextData();
      final corrupted = Uint8List.fromList(png);
      final textOffset = _pngTextChunkOffset(corrupted, 'Description');
      expect(textOffset, isNotNull);
      corrupted[textOffset! + 8] ^= 0x01;

      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        corrupted,
      );

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, isNull);
      expect(img.decodeJpgExif(result.jpegBytes!)?.exifIfd.userComment, isNull);
    });

    test('falls back to valid text when the stealth metadata is malformed',
        () async {
      final image = img.Image(width: 64, height: 48, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(80, 120, 160, 255));
      image.addTextData({
        'Title': 'AI generated image',
        'Description': 'text fallback prompt',
        'Software': 'NovelAI',
        'Source': 'NovelAI Diffusion V5 fixture',
        'Comment': '{"prompt":"text fallback prompt","steps":28}',
      });
      final png = _pngWithMalformedStealthAndText(
        Uint8List.fromList(img.encodePng(image)),
      );

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, contains('text fallback prompt'));
    });

    test('ignores unrelated stealth JSON when PNG text has NovelAI metadata',
        () async {
      final png = await _pngWithStealthMetadataAndText(
        _opaquePngWithTextData(),
        '{"unrelated":true}',
      );

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, contains('fixture prompt'));
      expect(result.metadataJson, isNot(contains('unrelated')));
    });

    test('drops XML-invalid controls from the optional XMP mirror', () async {
      final metadata = <String, Object?>{
        'Title': 'fixture\u0001title',
        'Description': 'positive\u0002prompt',
        'Software': 'NovelAI',
        'Source': 'fixture source',
        'Comment': '{"prompt":"positive prompt","steps":28}',
      };
      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        _pngWithLargeNovelAiTextData(metadata),
      );

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      final xmp = _xmpPacket(result.jpegBytes!);
      expect(xmp, isNotNull);
      expect(xmp, isNot(contains('\u0001')));
      expect(xmp, isNot(contains('\u0002')));
      expect(img.decodeJpg(result.jpegBytes!), isNotNull);
    });

    test(
        'writes the EXIF UserComment with the standard ASCII charset prefix '
        'required by the NovelAI website reader', () async {
      const metadata = <String, Object?>{
        'Description': 'prompt',
        'Software': 'NovelAI',
        'Comment': '{"steps":28,"width":19}',
      };
      final png = await ImageService().embedMetadata(
        _opaquePng(width: 64, height: 48),
        jsonEncode(metadata),
      );

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded);
      final raw = _rawExifUserCommentBytes(result.jpegBytes!);
      expect(raw, isNotNull);
      expect(
        raw!.take(8).toList(),
        [0x41, 0x53, 0x43, 0x49, 0x49, 0x00, 0x00, 0x00],
      );
      expect(
        jsonDecode(String.fromCharCodes(raw.skip(8))),
        jsonDecode(result.metadataJson!),
      );
    });

    test('mirrors NovelAI metadata into XMP and IPTC compatibility fields',
        () async {
      const metadata = <String, Object?>{
        'Title': 'fixture title',
        'Description': 'positive prompt',
        'Software': 'NovelAI',
        'Source': 'Stable Diffusion XL',
        'Comment':
            '{"prompt":"positive prompt","negative_prompt":"negative prompt","steps":28}',
      };
      final png = await ImageService().embedMetadata(
        _opaquePng(width: 64, height: 48),
        jsonEncode(metadata),
      );

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded);
      final jpeg = result.jpegBytes!;
      final xmp = _xmpPacket(jpeg);
      expect(xmp, contains('positive prompt'));
      expect(xmp, contains('negative prompt'));
      expect(xmp, contains('NovelAI'));
      expect(xmp, contains('Stable Diffusion XL'));
      final iptc = _iptcPayload(jpeg);
      expect(iptc, contains('positive prompt'));
      expect(iptc, contains('negative prompt'));
      expect(iptc, contains('Stable Diffusion XL'));
      expect(_iptcHasDataset(iptc, 115), isTrue);
      expect(_iptcHasDataset(iptc, 110), isFalse);
    });

    test('bounds long XMP mirror fields without dropping the JPEG', () async {
      final longSoftware = List<String>.filled(20000, '<').join();
      final metadata = <String, Object?>{
        'Title': 'fixture title',
        'Description': 'positive prompt',
        'Software': longSoftware,
        'Source': 'fixture source',
        'Comment': '{"prompt":"positive prompt","steps":28}',
      };
      final png = _pngWithLargeNovelAiTextData(metadata);

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(img.decodeJpg(result.jpegBytes!), isNotNull);
      expect(
        utf8.encode(_xmpPacket(result.jpegBytes!)!).length,
        lessThanOrEqualTo(0xffff -
            2 -
            utf8.encode('http://ns.adobe.com/xap/1.0/\u0000').length),
      );
    });

    test('metadata erase removes source PNG text before JPEG extraction',
        () async {
      final image = img.Image(width: 64, height: 48, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(80, 120, 160, 255));
      image.addTextData({
        'Title': 'AI generated image',
        'Description': 'must be erased',
        'Software': 'NovelAI',
        'Source': 'NovelAI Diffusion V5 fixture',
        'Comment': '{"prompt":"must be erased","steps":28}',
      });
      final png = await ImageService().embedMetadata(
        Uint8List.fromList(img.encodePng(image)),
        '',
      );

      expect(img.decodePng(png)?.textData, anyOf(isNull, isEmpty));
      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded,
          reason: result.errorMessage);
      expect(result.metadataJson, isNull);
      expect(img.decodeJpgExif(result.jpegBytes!)?.exifIfd.userComment, isNull);
    });

    test('erased metadata does not leak into JPEG EXIF mirror fields',
        () async {
      final png = await ImageService().embedMetadata(
        _opaquePng(width: 64, height: 48),
        '',
      );

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded);
      expect(result.metadataJson, isNull);
      final exif = img.decodeJpgExif(result.jpegBytes!);
      expect(exif?.exifIfd.userComment, isNull);
      expect(exif?.imageIfd.imageDescription, isNull);
      expect(exif?.imageIfd.software, isNull);
    });

    test('returns an explicit unsupported result for transparent PNGs',
        () async {
      final image = img.Image(width: 9, height: 7, numChannels: 4);
      image.setPixelRgba(0, 0, 255, 0, 0, 127);
      final png = Uint8List.fromList(img.encodePng(image));

      final result = await const IsolateGeneratedImageJpegEncoder().encode(png);

      expect(result.status,
          GeneratedImageJpegEncodingStatus.transparencyUnsupported);
      expect(result.jpegBytes, isNull);
      expect(result.width, 9);
      expect(result.height, 7);
      expect(result.hasTransparency, isTrue);
      expect(result.errorMessage, contains('transparent'));
    });

    test('treats NovelAI near-opaque alpha 254 as JPEG eligible', () async {
      final image = img.Image(width: 9, height: 7, numChannels: 4);
      for (final pixel in image) {
        pixel
          ..r = 40
          ..g = 80
          ..b = 120
          ..a = 254;
      }

      final result = await const IsolateGeneratedImageJpegEncoder().encode(
        Uint8List.fromList(img.encodePng(image)),
      );

      expect(result.status, GeneratedImageJpegEncodingStatus.encoded);
      expect(result.hasTransparency, isFalse);
      expect(result.jpegBytes, isNotNull);
    });

    test('performs decoding and encoding outside the caller isolate', () async {
      final mainIsolate = Isolate.current.debugName;
      final result = await const IsolateGeneratedImageJpegEncoder()
          .encode(_opaquePng(width: 8, height: 8));

      expect(result.performedInBackgroundIsolate, isTrue);
      expect(result.workerIsolateDebugName, isNot(mainIsolate));
    });
  });
}

Uint8List _opaquePngWithTextData() {
  final image = img.Image(width: 64, height: 48, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(80, 120, 160, 255));
  image.addTextData({
    'Title': 'AI generated image',
    'Description': 'fixture prompt',
    'Software': 'NovelAI',
    'Source': 'NovelAI Diffusion V5 0ADF9AB7',
    'Comment': '{"prompt":"fixture prompt","steps":28}',
  });
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _pngWithMalformedStealthAndText(Uint8List png) {
  final image = img.decodePng(png)!;
  final data = <int>[
    ...ascii.encode('stealth_pngcomp'),
    0,
    0,
    0,
    8,
    0,
  ];
  var bitIndex = 0;
  for (var x = 0; x < image.width; x++) {
    for (var y = 0; y < image.height; y++) {
      final byteIndex = bitIndex ~/ 8;
      if (byteIndex >= data.length) break;
      final bit = (data[byteIndex] >> (7 - bitIndex % 8)) & 1;
      final pixel = image.getPixel(x, y);
      pixel.a = (pixel.a.toInt() & 0xfe) | bit;
      image.setPixel(x, y, pixel);
      bitIndex++;
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Future<Uint8List> _pngWithStealthMetadataAndText(
  Uint8List png,
  String metadata,
) async {
  final image = img.decodePng(png)!;
  final encodedData = await GZip().compress(utf8.encode(metadata));
  final bitLengthBytes = ByteData(4)..setInt32(0, encodedData.length * 8);
  final data = <int>[
    ...ascii.encode('stealth_pngcomp'),
    ...bitLengthBytes.buffer.asUint8List(),
    ...encodedData,
  ];
  var bitIndex = 0;
  for (var x = 0; x < image.width; x++) {
    for (var y = 0; y < image.height; y++) {
      final byteIndex = bitIndex ~/ 8;
      if (byteIndex >= data.length) break;
      final bit = (data[byteIndex] >> (7 - bitIndex % 8)) & 1;
      final pixel = image.getPixel(x, y);
      pixel.a = (pixel.a.toInt() & 0xfe) | bit;
      image.setPixel(x, y, pixel);
      bitIndex++;
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _pngWithLargeNovelAiTextData(Map<String, Object?> metadata) {
  final image = img.Image(width: 64, height: 48, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(80, 120, 160, 255));
  image.addTextData({
    for (final entry in metadata.entries)
      entry.key: entry.value is String
          ? entry.value as String
          : jsonEncode(entry.value),
  });
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List? _rawExifUserCommentBytes(Uint8List jpeg) {
  var offset = 2;
  while (offset + 4 < jpeg.length) {
    final marker = jpeg[offset + 1];
    final length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    if (length < 2 || offset + 2 + length > jpeg.length) return null;
    if (marker == 0xe1) {
      final app1 = Uint8List.sublistView(jpeg, offset + 4, offset + 4 + length);
      if (app1.length >= 6 &&
          String.fromCharCodes(app1.take(6)) == 'Exif\u0000\u0000') {
        return _userCommentFromExif(Uint8List.sublistView(app1, 6));
      }
    }
    offset += 2 + length;
  }
  return null;
}

String? _xmpPacket(Uint8List jpeg) {
  final payload = _jpegAppSegment(
    jpeg,
    0xe1,
    'http://ns.adobe.com/xap/1.0/\u0000',
  );
  return payload == null ? null : String.fromCharCodes(payload);
}

String? _iptcPayload(Uint8List jpeg) {
  final payload = _jpegAppSegment(jpeg, 0xed, 'Photoshop 3.0\u0000');
  return payload == null ? null : String.fromCharCodes(payload);
}

bool _iptcHasDataset(String? payload, int dataset) {
  if (payload == null) return false;
  final bytes = payload.codeUnits;
  for (var index = 0; index + 2 < bytes.length; index++) {
    if (bytes[index] == 0x1c &&
        bytes[index + 1] == 2 &&
        bytes[index + 2] == dataset) {
      return true;
    }
  }
  return false;
}

Uint8List? _jpegAppSegment(Uint8List jpeg, int marker, String prefix) {
  var offset = 2;
  while (offset + 4 < jpeg.length && jpeg[offset] == 0xff) {
    final current = jpeg[offset + 1];
    if (current == 0xda || current == 0xd9) break;
    final length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
    if (length < 2 || offset + 2 + length > jpeg.length) return null;
    if (current == marker) {
      final data = Uint8List.sublistView(
        jpeg,
        offset + 4,
        offset + 2 + length,
      );
      if (String.fromCharCodes(data.take(prefix.length)) == prefix) {
        return Uint8List.sublistView(data, prefix.length);
      }
    }
    offset += 2 + length;
  }
  return null;
}

Uint8List? _userCommentFromExif(Uint8List exif) {
  if (exif.length < 14) return null;
  final bigEndian = exif[0] == 0x4d;
  int u16(int index) => bigEndian
      ? (exif[index] << 8) | exif[index + 1]
      : exif[index] | (exif[index + 1] << 8);
  int u32(int index) => bigEndian
      ? (exif[index] << 24) |
          (exif[index + 1] << 16) |
          (exif[index + 2] << 8) |
          exif[index + 3]
      : exif[index] |
          (exif[index + 1] << 8) |
          (exif[index + 2] << 16) |
          (exif[index + 3] << 24);

  final ifd0 = u32(4);
  int? exifIfdOffset;
  final ifd0Count = u16(ifd0);
  for (var index = 0; index < ifd0Count; index++) {
    final entry = ifd0 + 2 + (12 * index);
    if (u16(entry) == 0x8769) exifIfdOffset = u32(entry + 8);
  }
  if (exifIfdOffset == null) return null;

  final exifCount = u16(exifIfdOffset);
  for (var index = 0; index < exifCount; index++) {
    final entry = exifIfdOffset + 2 + (12 * index);
    if (u16(entry) != 0x9286) continue;
    final count = u32(entry + 4);
    final value = count > 4 ? u32(entry + 8) : entry + 8;
    if (value + count > exif.length) return null;
    return Uint8List.sublistView(exif, value, value + count);
  }
  return null;
}

Uint8List _opaquePng({required int width, required int height}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, (x * 17) % 256, (y * 23) % 256, 128, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _pngWithNovelAiITXt({required bool compressed}) {
  final png = _opaquePng(width: 64, height: 48);
  final fields = <String, String>{
    'Title': 'AI generated image',
    'Description': 'itxt prompt',
    'Software': 'NovelAI',
    'Source': 'NovelAI Diffusion V5 fixture',
    'Comment':
        '{"prompt":"itxt prompt","negative_prompt":"itxt negative","steps":28}',
  };
  final chunks = fields.entries
      .map((entry) =>
          _pngITXtChunk(entry.key, entry.value, compressed: compressed))
      .expand((chunk) => chunk);
  final iendOffset = png.length - 12;
  return Uint8List.fromList([
    ...png.sublist(0, iendOffset),
    ...chunks,
    ...png.sublist(iendOffset),
  ]);
}

Uint8List _pngWithNovelAiLatin1Text() {
  final png = _opaquePng(width: 64, height: 48);
  final fields = <String, List<int>>{
    'Title': latin1.encode('AI generated image'),
    'Description': latin1.encode('café prompt'),
    'Software': latin1.encode('NovelAI'),
    'Source': latin1.encode('NovelAI Diffusion V5 fixture'),
    'Comment': latin1.encode('{"prompt":"café prompt","steps":28}'),
  };
  final chunks = fields.entries
      .map((entry) => _pngTextChunk(entry.key, entry.value))
      .expand((chunk) => chunk);
  final iendOffset = png.length - 12;
  return Uint8List.fromList([
    ...png.sublist(0, iendOffset),
    ...chunks,
    ...png.sublist(iendOffset),
  ]);
}

List<int> _pngTextChunk(String keyword, List<int> textBytes) {
  final data = <int>[...ascii.encode(keyword), 0, ...textBytes];
  final type = ascii.encode('tEXt');
  return [
    ..._pngUint32(data.length),
    ...type,
    ...data,
    ..._pngUint32(getCrc32([...type, ...data])),
  ];
}

List<int> _pngITXtChunk(
  String keyword,
  String text, {
  required bool compressed,
  int? compressionFlagOverride,
}) {
  final textBytes = compressed
      ? const ZLibEncoder().encode(utf8.encode(text))
      : utf8.encode(text);
  final data = <int>[
    ...utf8.encode(keyword),
    0,
    compressionFlagOverride ?? (compressed ? 1 : 0),
    0,
    0,
    0,
    ...textBytes,
  ];
  final type = ascii.encode('iTXt');
  final crc = getCrc32([...type, ...data]);
  return [
    ..._pngUint32(data.length),
    ...type,
    ...data,
    ..._pngUint32(crc),
  ];
}

List<int> _pngUint32(int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.big);
  return bytes.buffer.asUint8List();
}

int? _pngTextChunkOffset(Uint8List bytes, String keyword) {
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final length = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    if (length < 0 || offset + 12 + length > bytes.length) return null;
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
    if (type == 'tEXt') {
      final payload = bytes.sublist(offset + 8, offset + 8 + length);
      final separator = payload.indexOf(0);
      if (separator > 0 &&
          String.fromCharCodes(payload.sublist(0, separator)) == keyword) {
        return offset;
      }
    }
    offset += 12 + length;
    if (type == 'IEND') return null;
  }
  return null;
}

Matcher _hasSof444AndDimensions(int width, int height) =>
    predicate<Uint8List?>((bytes) {
      if (bytes == null) return false;
      for (var i = 2; i + 16 < bytes.length; i++) {
        if (bytes[i] != 0xff || bytes[i + 1] != 0xc0) continue;
        final segmentLength = (bytes[i + 2] << 8) | bytes[i + 3];
        if (segmentLength < 17 || i + 2 + segmentLength > bytes.length) {
          return false;
        }
        final parsedHeight = (bytes[i + 5] << 8) | bytes[i + 6];
        final parsedWidth = (bytes[i + 7] << 8) | bytes[i + 8];
        final componentCount = bytes[i + 9];
        if (parsedWidth != width ||
            parsedHeight != height ||
            componentCount != 3) {
          return false;
        }
        // Y component's horizontal/vertical sampling factors are both 1.
        return bytes[i + 11] == 0x11;
      }
      return false;
    });

Matcher _hasQuality92LumaQuantization() => predicate<Uint8List?>((bytes) {
      if (bytes == null) return false;
      for (var i = 2; i + 69 < bytes.length; i++) {
        if (bytes[i] != 0xff || bytes[i + 1] != 0xdb) continue;
        final length = (bytes[i + 2] << 8) | bytes[i + 3];
        if (length < 67 || i + 2 + length > bytes.length || bytes[i + 4] != 0) {
          continue;
        }
        const expected = <int>[
          3,
          2,
          2,
          2,
          2,
          2,
          3,
          2,
          2,
          2,
          3,
          3,
          3,
          3,
          4,
          6,
          4,
          4,
          4,
          4,
          4,
          8,
          6,
          6,
          5,
          6,
          9,
          8,
          10,
          10,
          9,
          8,
          9,
          9,
          10,
          12,
          15,
          12,
          10,
          11,
          14,
          11,
          9,
          9,
          13,
          17,
          13,
          14,
          15,
          16,
          16,
          17,
          16,
          10,
          12,
          18,
          19,
          18,
          16,
          19,
          15,
          16,
          16,
          16,
        ];
        return List<int>.generate(64, (index) => bytes[i + 5 + index])
                .toString() ==
            expected.toString();
      }
      return false;
    });
