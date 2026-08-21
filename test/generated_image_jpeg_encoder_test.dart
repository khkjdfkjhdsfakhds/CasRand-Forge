import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
        _jsonEncode(metadata),
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
        _jsonEncode(metadata),
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

String _jsonEncode(Map<String, Object?> value) {
  // The fixture only needs stable JSON; production compacts/escapes this
  // independently before writing UserComment.
  return '{"Description":"a café ✨","Software":"NovelAI","Source":"Stable Diffusion XL","Generation time":"1.25","Title":"fixture","Comment":"{\\"prompt\\":\\"café\\",\\"steps\\":28,\\"width\\":19}"}';
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
