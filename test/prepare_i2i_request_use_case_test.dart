import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

Uint8List solidPng(int width, int height, int r, int g, int b) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List maskPngWithWhiteRect(
  int width,
  int height,
  int rx,
  int ry,
  int rw,
  int rh,
) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fillRect(
    image,
    x1: rx,
    y1: ry,
    x2: rx + rw - 1,
    y2: ry + rh - 1,
    color: img.ColorRgb8(255, 255, 255),
  );
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  setUp(PrepareI2iRequestUseCase.clearCache);

  test('img2img plan cover-fits the base image to the target size', () async {
    final config = I2IConfig()..setImage(solidPng(500, 300, 200, 30, 30));
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan, isNotNull);
    expect(plan!.isInpaint, isFalse);
    expect(plan.width, 832);
    expect(plan.height, 1216);
    expect(plan.composite, isNull);
    final sent = img.decodePng(base64Decode(plan.imageB64))!;
    expect(sent.width, 832);
    expect(sent.height, 1216);
  });

  test('img2img plan sends original bytes when size already matches',
      () async {
    final original = solidPng(832, 1216, 10, 200, 10);
    final config = I2IConfig()..setImage(original);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(base64Decode(plan!.imageB64), original);
  });

  test('compliant inpaint image goes whole-image direct with quantized mask',
      () async {
    final config = I2IConfig()..setImage(solidPng(832, 1216, 0, 0, 255));
    config.setMask(maskPngWithWhiteRect(832, 1216, 100, 100, 60, 40), []);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.isInpaint, isTrue);
    expect(plan.width, 832);
    expect(plan.height, 1216);
    expect(plan.composite, isNull, reason: 'direct result needs no composite');
    final mask = img.decodePng(base64Decode(plan.maskB64!))!;
    expect(mask.width, 832);
    expect(mask.height, 1216);
    // Mask cells cover pixels 96..160 x 96..144 (8px cell expansion).
    expect(mask.getPixel(120, 120).r, 255);
    expect(mask.getPixel(90, 90).r, 0);
    expect(mask.getPixel(400, 400).r, 0);
    // Quantization keeps whole 8px cells white.
    expect(mask.getPixel(97, 97).r, 255);
  });

  test('large inpaint image gets a native autocrop window plan', () async {
    final config = I2IConfig()..setImage(solidPng(1600, 2400, 90, 90, 90));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.isInpaint, isTrue);
    expect(plan.composite, isNotNull);
    expect(plan.composite!.scaled, isFalse);
    expect(plan.width % 64, 0);
    expect(plan.height % 64, 0);
    final tile = img.decodePng(base64Decode(plan.imageB64))!;
    expect(tile.width, plan.width);
    expect(tile.height, plan.height);
    final mask = img.decodePng(base64Decode(plan.maskB64!))!;
    expect(mask.width, plan.width);
    expect(mask.height, plan.height);
    // The mask must contain white cells (the crop kept the masked region).
    var whiteCount = 0;
    for (var y = 0; y < mask.height; y += 8) {
      for (var x = 0; x < mask.width; x += 8) {
        if (mask.getPixel(x, y).r > 127) whiteCount++;
      }
    }
    expect(whiteCount, greaterThan(0));
  });

  test('autocrop off scales the whole image to a compliant size', () async {
    final config = I2IConfig()..setImage(solidPng(1600, 2400, 90, 90, 90));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    config.setAutocropEnabled(false);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.composite, isNull);
    expect(plan.width % 64, 0);
    expect(plan.height % 64, 0);
    expect(plan.width * plan.height, lessThanOrEqualTo(1024 * 1024));
  });

  test('empty mask throws a descriptive error', () async {
    final config = I2IConfig()..setImage(solidPng(832, 1216, 0, 0, 255));
    config.setMask(maskPngWithWhiteRect(832, 1216, 0, 0, 1, 1), []);
    // Overwrite with an all-black mask (the rect helper always paints one).
    final black = img.Image(width: 832, height: 1216, numChannels: 3);
    config.setMask(Uint8List.fromList(img.encodePng(black)), []);
    expect(
      () => PrepareI2iRequestUseCase(config: config)(
        targetWidth: 832,
        targetHeight: 1216,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('native composite pastes the tile back at the window position',
      () async {
    final config = I2IConfig()..setImage(solidPng(1600, 2400, 200, 0, 0));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final plan = await useCase(targetWidth: 832, targetHeight: 1216);
    final composite = plan!.composite!;
    final tileBytes = solidPng(plan.width, plan.height, 0, 0, 200);
    final resultBytes = await useCase.compositeResponse(
      responseBytes: tileBytes,
      composite: composite,
    );
    final result = img.decodePng(resultBytes)!;
    expect(result.width, 1600);
    expect(result.height, 2400);
    // Inside the window: tile color (blue).
    final inX = composite.window.x + composite.window.w ~/ 2;
    final inY = composite.window.y + composite.window.h ~/ 2;
    expect(result.getPixel(inX, inY).b, greaterThan(150));
    expect(result.getPixel(inX, inY).r, lessThan(50));
    // Far corner outside the window: original color (red).
    expect(result.getPixel(10, 10).r, greaterThan(150));
    expect(result.getPixel(10, 10).b, lessThan(50));
  });

  test('scaled composite blends only the masked area', () async {
    final config = I2IConfig()..setImage(solidPng(2000, 3000, 200, 0, 0));
    config.setMask(maskPngWithWhiteRect(2000, 3000, 100, 100, 1800, 2800), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final plan = await useCase(targetWidth: 832, targetHeight: 1216);
    final composite = plan!.composite!;
    expect(composite.scaled, isTrue);
    final tileBytes = solidPng(plan.width, plan.height, 0, 0, 200);
    final resultBytes = await useCase.compositeResponse(
      responseBytes: tileBytes,
      composite: composite,
    );
    final result = img.decodePng(resultBytes)!;
    expect(result.width, 2000);
    expect(result.height, 3000);
    // Deep inside the mask: tile color wins.
    expect(result.getPixel(1000, 1500).b, greaterThan(150));
    // Just outside the mask near the corner: original red remains.
    expect(result.getPixel(20, 20).r, greaterThan(150));
    expect(result.getPixel(20, 20).b, lessThan(80));
  });
}
