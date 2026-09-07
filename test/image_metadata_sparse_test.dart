import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/services/generated_image_jpeg_encoder.dart';
import 'package:nai_casrand/data/services/image_service.dart';

Uint8List _png(Map<String, dynamic> metadata, {int size = 64}) {
  final source = img.Image(width: size, height: size, numChannels: 4);
  img.fill(source, color: img.ColorRgb8(70, 120, 180));
  source.addTextData(metadata.map((key, value) =>
      MapEntry(key, value is String ? value : jsonEncode(value))));
  return Uint8List.fromList(img.encodePng(source));
}

void main() {
  for (final description in [null, '', '   ']) {
    final metadata = <String, dynamic>{
      'Software': 'NovelAI',
      if (description != null) 'Description': description,
      'Comment':
          jsonEncode({'steps': 28, 'seed': 42, 'sampler': 'k_euler_ancestral'}),
    };
    for (final carrier in ['text', 'stealth', 'itxt']) {
      test(
          'IMG-06 sparse generation record survives $carrier description=$description',
          () async {
        final bytes = carrier == 'text'
            ? _png(metadata)
            : await ImageService().embedMetadata(
                _png({}, size: carrier == 'itxt' ? 8 : 128),
                jsonEncode(metadata));
        final extracted = await ImageService().extractMetadataFromBytes(bytes);
        expect(extracted, isNotNull);
        expect(jsonDecode(extracted!), metadata);
      });
    }
    test(
        'IMG-06 sparse generation record survives PNG to JPEG to import description=$description',
        () async {
      final jpeg =
          await const IsolateGeneratedImageJpegEncoder().encode(_png(metadata));
      expect(jpeg.isSuccess, isTrue, reason: jpeg.errorMessage);
      final extracted =
          await ImageService().extractMetadataFromBytes(jpeg.jpegBytes!);
      expect(jsonDecode(extracted!), metadata);
    });
  }
  for (final metadata in <Map<String, dynamic>>[
    {'Software': 'NovelAI', 'Description': '', 'Comment': '{}'},
    {'Software': 'Unrelated', 'Comment': '{"steps":28}'},
    {'Description': '', 'Comment': '{"steps":28}'},
    {'Software': 'NovelAI', 'Comment': '{"unrelated":true}'},
    {'Software': 'NovelAI', 'Comment': 'not-json'},
    {'Software': 'NovelAI', 'Description': 42, 'Comment': '{"steps":28}'},
  ]) {
    test(
        'IMG-06 unrelated or malformed sparse metadata is not imported: $metadata',
        () async {
      // EXIF preserves value types in the envelope, unlike PNG string fields.
      final source = img.Image(width: 8, height: 8);
      source.exif.exifIfd.userComment =
          'ASCII\u0000\u0000\u0000${jsonEncode(metadata)}';
      expect(
          await ImageService().extractMetadataFromBytes(
              Uint8List.fromList(img.encodeJpg(source))),
          isNull);
    });
  }
}
