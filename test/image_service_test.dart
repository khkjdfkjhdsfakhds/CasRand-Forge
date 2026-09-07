import 'dart:typed_data';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/services/generated_image_jpeg_encoder.dart';
import 'package:nai_casrand/data/services/image_service.dart';

Uint8List responseArchive(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  test('all numbered response images are returned in index order', () {
    final bytes = responseArchive({
      'image_2.png': Uint8List.fromList([2]),
      'metadata.json': Uint8List.fromList([9]),
      'image_0.png': Uint8List.fromList([0]),
      'image_1.png': Uint8List.fromList([1]),
    });

    final images = ImageService().processResponseImages(bytes);

    expect(images, hasLength(3));
    expect(images.map((image) => image.single), [0, 1, 2]);
    expect(ImageService().processResponse(bytes).single, 0);
  });

  test('a response without image zero is rejected', () {
    final bytes = responseArchive({
      'image_1.png': Uint8List.fromList([1]),
    });

    expect(
      () => ImageService().processResponseImages(bytes),
      throwsA(isA<Exception>()),
    );
  });

  test('a JSON error body is rejected as non-ZIP without an EOCD error', () {
    final bytes = Uint8List.fromList(utf8.encode(
      '{"statusCode":500,"message":"i/o timeout"}',
    ));

    expect(
      () => ImageService().processResponseImages(bytes),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('unexpected non-ZIP') &&
              error.toString().contains('i/o timeout') &&
              !error.toString().contains('End of Central Directory'),
        ),
      ),
    );
  });

  test('embedding metadata preserves transparent and partial alpha', () async {
    final image = img.Image(width: 64, height: 64, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(20, 40, 60, 0));
    image.setPixelRgba(10, 10, 20, 40, 60, 128);
    image.setPixelRgba(20, 20, 20, 40, 60, 255);

    final embedded = await ImageService().embedMetadata(
      Uint8List.fromList(img.encodePng(image)),
      '{"tool":"bg-removal"}',
    );
    final decoded = img.decodePng(embedded)!;

    expect(decoded.getPixel(0, 0).a, lessThanOrEqualTo(1));
    expect(decoded.getPixel(10, 10).a, inInclusiveRange(128, 129));
    expect(decoded.getPixel(20, 20).a, inInclusiveRange(254, 255));
  });

  test('byte metadata import preserves the existing PNG stealth contract',
      () async {
    const metadata =
        '{"Description":"png prompt","Software":"NovelAI","Comment":"{\\"steps\\":28}"}';
    final image = img.Image(width: 96, height: 96, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(20, 40, 60, 255));
    final png = await ImageService().embedMetadata(
      Uint8List.fromList(img.encodePng(image)),
      metadata,
    );

    expect(await ImageService().extractMetadataFromBytes(png), metadata);
    expect(
      await ImageService().extractMetadataFromBytesInBackground(png),
      metadata,
    );
  });

  test('reads the authoritative NovelAI outer JSON from JPEG UserComment',
      () async {
    const metadata =
        '{"Description":"prompt","Software":"NovelAI","Source":"Stable Diffusion XL","Comment":"{\\"uc\\":\\"negative\\",\\"seed\\":42,\\"steps\\":28}"}';
    final image = img.Image(width: 128, height: 128, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(80, 120, 160, 255));
    final png = await ImageService().embedMetadata(
      Uint8List.fromList(img.encodePng(image)),
      metadata,
    );
    expect(await ImageService().extractMetadata(img.decodePng(png)!), metadata);
    final encoded = await const IsolateGeneratedImageJpegEncoder().encode(png);
    expect(encoded.status, GeneratedImageJpegEncodingStatus.encoded,
        reason: encoded.errorMessage);
    expect(encoded.metadataJson, isNotNull);

    final extracted = await ImageService().extractMetadataFromBytes(
      encoded.jpegBytes!,
    );

    expect(jsonDecode(extracted!), jsonDecode(metadata));
  });

  test('malformed or unrelated JPEG UserComment is rejected safely', () async {
    final image = img.Image(width: 8, height: 8, numChannels: 3);
    image.exif.exifIfd.userComment = 'not NovelAI JSON';
    final jpeg = Uint8List.fromList(img.encodeJpg(image));

    expect(await ImageService().extractMetadataFromBytes(jpeg), isNull);
    expect(
      await ImageService().extractMetadataFromBytes(
        Uint8List.fromList([0xff, 0xd8, 0x00, 0x01]),
      ),
      isNull,
    );
  });

  test('JPEG without metadata remains an ordinary importable image', () async {
    final image = img.Image(width: 8, height: 8, numChannels: 3);
    final jpeg = Uint8List.fromList(img.encodeJpg(image));

    expect(await ImageService().extractMetadataFromBytes(jpeg), isNull);
  });
}
