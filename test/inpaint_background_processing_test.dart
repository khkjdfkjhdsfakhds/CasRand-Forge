import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

Uint8List _solidPng(int width, int height, int r, int g, int b) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _maskPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fillRect(
    image,
    x1: width ~/ 4,
    y1: height ~/ 4,
    x2: width * 3 ~/ 4 - 1,
    y2: height * 3 ~/ 4 - 1,
    color: img.ColorRgb8(255, 255, 255),
  );
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  setUp(PrepareI2iRequestUseCase.clearCache);

  test('inpaint preparation discards stale work when the image changes',
      () async {
    final first = _solidPng(1024, 1024, 220, 20, 20);
    final second = _solidPng(1024, 1024, 20, 220, 20);
    final mask = _maskPng(1024, 1024);
    final config = I2IConfig()..setImage(first);
    config.setMask(mask, []);
    final useCase = PrepareI2iRequestUseCase(config: config);

    final pending = useCase.planBatch(targetWidth: 832, targetHeight: 1216);
    config.setImage(second);
    config.setMask(mask, []);

    final batch = await pending;
    expect(batch, isNotNull);
    final prepared = img.decodePng(
      base64Decode(batch!.plans.single.imageB64),
    )!;
    final pixel = prepared.getPixel(0, 0);
    expect(pixel.g, greaterThan(pixel.r));
    expect(batch.plans.single.isInpaint, isTrue);
  });
}
