import 'dart:convert';
import 'dart:typed_data';

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

Uint8List responsePng(int red) {
  final image = img.Image(width: 2, height: 2, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(red, 20, 30));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('all numbered response images are returned in index order', () {
    final bytes = responseArchive({
      'image_2.png': responsePng(2),
      'metadata.json': Uint8List.fromList([9]),
      'image_0.png': responsePng(0),
      'image_1.png': responsePng(1),
    });

    final images = ImageService().processResponseImages(bytes);

    expect(images, hasLength(3));
    expect(images.sampleIndices, [0, 1, 2]);
    expect(images[0], responsePng(0));
    expect(ImageService().processResponse(bytes), responsePng(0));
  });

  test('multi-sample parsing preserves a valid later sample when zero is lost',
      () {
    final bytes = responseArchive({
      'image_1.png': responsePng(1),
    });

    final images = ImageService().processResponseImages(
      bytes,
      expectedSampleCount: 2,
    );

    expect(images, hasLength(1));
    expect(images.sampleIndices, [1]);
    expect(images.missingSampleIndices, [0]);
    expect(
      () => ImageService().processResponse(bytes),
      throwsA(isA<Exception>()),
    );
  });

  test('missing archive members keep later samples and report incompleteness',
      () {
    final bytes = responseArchive({
      'image_0.png': responsePng(10),
      'image_2.png': responsePng(30),
    });

    final images = ImageService().processResponseImages(bytes);

    expect(images.sampleIndices, [0, 2]);
    expect(images.missingSampleIndices, [1]);
    expect(images.incompleteWarning, contains('sample 2'));
  });

  test('corrupt and trailing samples are omitted and reported', () {
    final valid = responsePng(10);
    final bytes = responseArchive({
      'image_0.png': valid,
      'image_1.png': Uint8List.fromList(utf8.encode('not a PNG')),
    });

    final images = ImageService().processResponseImages(
      bytes,
      expectedSampleCount: 3,
    );

    expect(images, [valid]);
    expect(images.sampleIndices, [0]);
    expect(images.missingSampleIndices, [1, 2]);
    expect(images.incompleteWarning, contains('sample 2, 3'));
  });

  test('an archive with no valid PNG sample is rejected', () {
    final bytes = responseArchive({
      'image_0.png': Uint8List.fromList(utf8.encode('not a PNG')),
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

  test('empty metadata erasure leaves no stealth payload or text metadata',
      () async {
    final image = img.Image(width: 32, height: 32, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(20, 40, 60, 128));
    image.addTextData({'Description': 'must be erased'});
    final original = Uint8List.fromList(img.encodePng(image));

    final erased = await ImageService().embedMetadata(original, '   ');
    final decoded = img.decodePng(erased)!;

    expect(decoded.getPixel(0, 0).a, 128);
    expect(decoded.textData, anyOf(isNull, isEmpty));
    expect(await ImageService().extractMetadata(decoded), isNull);
  });

  test('metadata erasure clears an existing stealth payload', () async {
    const metadata =
        '{"Description":"stale prompt","Software":"NovelAI","Comment":"{\\"steps\\":28}"}';
    final embedded = await ImageService().embedMetadata(
      Uint8List.fromList(img.encodePng(
        img.Image(width: 64, height: 64, numChannels: 4),
      )),
      metadata,
    );

    expect(await ImageService().extractMetadataFromBytes(embedded), metadata);

    final erased = await ImageService().embedMetadata(embedded, '');

    expect(await ImageService().extractMetadataFromBytes(erased), isNull);
    expect(
      await ImageService().extractMetadata(img.decodePng(erased)!),
      isNull,
    );
  });

  test('small carriers fall back to recoverable PNG text metadata', () async {
    const metadata = '{"Description":"超长提示词 portrait portrait portrait",'
        '"Software":"NovelAI",'
        '"Comment":"{\\"prompt\\":\\"超长提示词\\",\\"steps\\":28}"}';
    final source = Uint8List.fromList(img.encodePng(
      img.Image(width: 8, height: 8, numChannels: 4),
    ));

    final outcome =
        await ImageService().embedMetadataWithOutcome(source, metadata);
    final embedded = outcome.bytes;

    expect(outcome.mode, ImageMetadataEmbeddingMode.pngInternationalText);
    expect(await ImageService().extractMetadataFromBytes(embedded), metadata);
    expect(
      await ImageService().extractMetadata(img.decodePng(embedded)!),
      isNull,
      reason: 'the undersized alpha carrier must not contain a truncated '
          'stealth envelope',
    );
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

  test('PNG iTXt metadata is readable when no stealth channel exists',
      () async {
    for (final compressed in [false, true]) {
      final png = _pngWithNovelAiITXt(compressed: compressed);
      final extracted = await ImageService().extractMetadataFromBytes(png);
      final extractedInBackground =
          await ImageService().extractMetadataFromBytesInBackground(png);

      expect(extracted, isNotNull);
      expect(extractedInBackground, isNotNull);
      expect(jsonDecode(extracted!), jsonDecode(extractedInBackground!));
      expect(jsonDecode(extracted)['Description'], 'itxt prompt');
      expect(
        jsonDecode(extracted)['Comment'],
        '{"prompt":"itxt prompt","steps":28}',
      );
    }
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

  test('stealth metadata with an intentionally empty prompt is retained',
      () async {
    const metadata =
        '{"Description":"","Software":"NovelAI","Comment":"{\\"steps\\":28}"}';
    final png = await ImageService().embedMetadata(
      Uint8List.fromList(img.encodePng(
        img.Image(width: 64, height: 64, numChannels: 4),
      )),
      metadata,
    );

    expect(await ImageService().extractMetadataFromBytes(png), metadata);
  });
}

Uint8List _pngWithNovelAiITXt({required bool compressed}) {
  final image = img.Image(width: 64, height: 48, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(80, 120, 160, 255));
  final png = Uint8List.fromList(img.encodePng(image));
  final fields = <String, String>{
    'Description': 'itxt prompt',
    'Software': 'NovelAI',
    'Source': 'NovelAI Diffusion V5 fixture',
    'Comment': '{"prompt":"itxt prompt","steps":28}',
  };
  final chunks = fields.entries
      .map((entry) => _pngITXtChunk(entry.key, entry.value, compressed))
      .expand((chunk) => chunk);
  final iendOffset = png.length - 12;
  return Uint8List.fromList([
    ...png.sublist(0, iendOffset),
    ...chunks,
    ...png.sublist(iendOffset),
  ]);
}

List<int> _pngITXtChunk(String keyword, String text, bool compressed) {
  final textBytes = compressed
      ? const ZLibEncoder().encode(utf8.encode(text))
      : utf8.encode(text);
  final data = <int>[
    ...ascii.encode(keyword),
    0,
    compressed ? 1 : 0,
    0,
    0,
    0,
    ...textBytes,
  ];
  final type = ascii.encode('iTXt');
  return [
    ..._pngUint32(data.length),
    ...type,
    ...data,
    ..._pngUint32(getCrc32([...type, ...data])),
  ];
}

List<int> _pngUint32(int value) {
  final bytes = ByteData(4)..setUint32(0, value, Endian.big);
  return bytes.buffer.asUint8List();
}
