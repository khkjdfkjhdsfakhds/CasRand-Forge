import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

Uint8List solidPng(int width, int height, int r, int g, int b) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

/// A base image with a distinct colour per quadrant, so compositing can be
/// checked positionally.
Uint8List quadrantPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final left = x < width ~/ 2;
      final top = y < height ~/ 2;
      final color = left
          ? (top ? img.ColorRgb8(200, 0, 0) : img.ColorRgb8(0, 200, 0))
          : (top ? img.ColorRgb8(0, 0, 200) : img.ColorRgb8(200, 200, 0));
      image.setPixel(x, y, color);
    }
  }
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

  test('img2img plan sends original bytes when size already matches', () async {
    final original = solidPng(832, 1216, 10, 200, 10);
    final config = I2IConfig()..setImage(original);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(base64Decode(plan!.imageB64), original);
  });

  test('focus inpaint sends a request canvas matching the plan', () async {
    final config = I2IConfig()..setImage(quadrantPng(1600, 2400));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.isInpaint, isTrue);
    expect(plan.composite, isNotNull);
    expect(plan.width % 64, 0);
    expect(plan.height % 64, 0);
    expect(plan.width * plan.height, lessThanOrEqualTo(1024 * 1024));
    final sent = img.decodePng(base64Decode(plan.imageB64))!;
    expect(sent.width, plan.width);
    expect(sent.height, plan.height);
    final mask = img.decodePng(base64Decode(plan.maskB64!))!;
    expect(mask.width, plan.width);
    expect(mask.height, plan.height);
    // The mask must carry white cells inside the request canvas.
    var white = 0;
    for (var y = 0; y < mask.height; y += 8) {
      for (var x = 0; x < mask.width; x += 8) {
        if (mask.getPixel(x, y).r > 127) white++;
      }
    }
    expect(white, greaterThan(0));
  });

  test('small image is magnified so the request uses the full budget',
      () async {
    final config = I2IConfig()..setImage(quadrantPng(512, 512));
    config.setMask(maskPngWithWhiteRect(512, 512, 200, 200, 60, 60), []);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.isInpaint, isTrue);
    final composite = plan.composite!;
    expect(composite.scale, greaterThan(1.0));
    expect(composite.isNativeScale, isFalse);
    // A 512x512 source must not be sent as a 512x512 request.
    expect(plan.width, greaterThan(512));
    expect(plan.width * plan.height, greaterThan((1024 * 1024 * 0.8).round()));
    final sent = img.decodePng(base64Decode(plan.imageB64))!;
    expect(sent.width, plan.width);
    expect(sent.height, plan.height);
  });

  test('a mask beyond one frame is split into focus tiles', () async {
    final config = I2IConfig()..setImage(solidPng(2000, 3000, 90, 90, 90));
    config.setMask(maskPngWithWhiteRect(2000, 3000, 50, 50, 1900, 2900), []);
    final batch = await PrepareI2iRequestUseCase(config: config).planBatch(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(batch!.isSplit, isTrue);
    expect(batch.tileCount, greaterThan(1));
    expect(batch.summary, contains('tiles'));
    for (final plan in batch.plans) {
      expect(plan.isInpaint, isTrue);
      expect(plan.composite, isNotNull);
      expect(plan.width % 64, 0);
      expect(plan.height % 64, 0);
      expect(plan.width * plan.height, lessThanOrEqualTo(1024 * 1024));
    }
    // Every tile must target a distinct frame.
    final frames = batch.plans.map((p) => p.composite!.outer).toSet();
    expect(frames.length, batch.tileCount);
  });

  test('a single-tile batch carries one plan', () async {
    final config = I2IConfig()..setImage(quadrantPng(1600, 2400));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final batch = await PrepareI2iRequestUseCase(config: config).planBatch(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(batch!.isSplit, isFalse);
    expect(batch.tileCount, 1);
    expect(batch.serial, isTrue);
  });

  test('a plain img2img batch carries one non-inpaint plan', () async {
    final config = I2IConfig()..setImage(solidPng(500, 300, 200, 30, 30));
    final batch = await PrepareI2iRequestUseCase(config: config).planBatch(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(batch!.tileCount, 1);
    expect(batch.plans.single.isInpaint, isFalse);
    expect(batch.plans.single.composite, isNull);
  });

  test('split tiles composite onto one accumulating canvas', () async {
    final config = I2IConfig()..setImage(quadrantPng(2000, 3000));
    config.setMask(maskPngWithWhiteRect(2000, 3000, 50, 50, 1900, 2900), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final batch = await useCase.planBatch(
      targetWidth: 832,
      targetHeight: 1216,
    );
    final canvas = useCase.newCompositeCanvas();
    expect(canvas.width, 2000);
    expect(canvas.height, 3000);

    // Paste a distinct colour per tile so every frame is verifiable.
    for (final (index, plan) in batch!.plans.indexed) {
      final shade = 20 + index * 10;
      useCase.pasteTileInto(
        canvas: canvas,
        responseBytes: solidPng(plan.width, plan.height, shade, shade, shade),
        composite: plan.composite!,
      );
    }
    final bytes = await useCase.finishComposite(
      canvas: canvas,
      responseBytes: solidPng(64, 64, 0, 0, 0),
    );
    final result = img.decodePng(bytes)!;
    expect(result.width, 2000);
    expect(result.height, 3000);

    // The union of the frames must have been repainted grey.
    final original = img.decodePng(quadrantPng(2000, 3000))!;
    var repainted = 0;
    for (final plan in batch.plans) {
      final outer = plan.composite!.outer;
      final x = outer.x + outer.w ~/ 2;
      final y = outer.y + outer.h ~/ 2;
      final after = result.getPixel(x, y);
      final before = original.getPixel(x, y);
      if (after.r != before.r || after.g != before.g) repainted++;
    }
    expect(repainted, batch.tileCount);
  });

  test('autocrop off always uses the whole-image path', () async {
    final config = I2IConfig()..setImage(solidPng(1600, 2400, 90, 90, 90));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    config.setAutocropEnabled(false);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.composite, isNull);
    expect(plan.summary, contains('whole image'));
    expect(plan.width * plan.height, lessThanOrEqualTo(1024 * 1024));
  });

  test('empty mask throws a descriptive error', () async {
    final config = I2IConfig()..setImage(solidPng(832, 1216, 0, 0, 255));
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

  test('composite restores the original size and leaves the outside intact',
      () async {
    final baseBytes = quadrantPng(1600, 2400);
    final config = I2IConfig()..setImage(baseBytes);
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final plan = await useCase(targetWidth: 832, targetHeight: 1216);
    final composite = plan!.composite!;
    final original = img.decodePng(baseBytes)!;

    // A uniformly coloured response makes the pasted region obvious.
    final responseBytes = solidPng(plan.width, plan.height, 12, 34, 56);
    final resultBytes = await useCase.compositeResponse(
      responseBytes: responseBytes,
      composite: composite,
    );
    final result = img.decodePng(resultBytes)!;
    expect(result.width, 1600);
    expect(result.height, 2400);

    // Inside the outer frame: the response colour.
    final inX = composite.outer.x + composite.outer.w ~/ 2;
    final inY = composite.outer.y + composite.outer.h ~/ 2;
    expect(result.getPixel(inX, inY).r, closeTo(12, 6));
    expect(result.getPixel(inX, inY).b, closeTo(56, 6));

    // Outside the frame: pixel-identical to the original.
    for (final point in [
      [2, 2],
      [1597, 2],
      [2, 2397],
      [1597, 2397],
    ]) {
      final x = point[0];
      final y = point[1];
      final inFrame = x >= composite.outer.x &&
          x < composite.outer.right &&
          y >= composite.outer.y &&
          y < composite.outer.bottom;
      if (inFrame) continue;
      expect(result.getPixel(x, y).r, original.getPixel(x, y).r);
      expect(result.getPixel(x, y).g, original.getPixel(x, y).g);
      expect(result.getPixel(x, y).b, original.getPixel(x, y).b);
    }
  });

  test('magnified composite scales the content back to the outer frame',
      () async {
    final baseBytes = quadrantPng(512, 512);
    final config = I2IConfig()..setImage(baseBytes);
    config.setMask(maskPngWithWhiteRect(512, 512, 200, 200, 60, 60), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final plan = await useCase(targetWidth: 832, targetHeight: 1216);
    final composite = plan!.composite!;
    expect(composite.isNativeScale, isFalse);

    final responseBytes = solidPng(plan.width, plan.height, 200, 0, 200);
    final resultBytes = await useCase.compositeResponse(
      responseBytes: responseBytes,
      composite: composite,
    );
    final result = img.decodePng(resultBytes)!;
    // The composed image keeps the source resolution, not the request one.
    expect(result.width, 512);
    expect(result.height, 512);
    final inX = composite.outer.x + composite.outer.w ~/ 2;
    final inY = composite.outer.y + composite.outer.h ~/ 2;
    expect(result.getPixel(inX, inY).r, closeTo(200, 8));
    expect(result.getPixel(inX, inY).g, closeTo(0, 8));
  });

  test('composite rejects a response smaller than the planned content',
      () async {
    final config = I2IConfig()..setImage(quadrantPng(1600, 2400));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final plan = await useCase(targetWidth: 832, targetHeight: 1216);
    expect(
      () => useCase.compositeResponse(
        responseBytes: solidPng(64, 64, 0, 0, 0),
        composite: plan!.composite!,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('plans are cached per config revision and target size', () async {
    final config = I2IConfig()..setImage(quadrantPng(1600, 2400));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final first = await useCase(targetWidth: 832, targetHeight: 1216);
    final second = await useCase(targetWidth: 832, targetHeight: 1216);
    expect(identical(first, second), isTrue);

    // Changing the mask must invalidate the cached plan.
    config.setMask(maskPngWithWhiteRect(1600, 2400, 100, 100, 120, 160), []);
    final third = await useCase(targetWidth: 832, targetHeight: 1216);
    expect(identical(first, third), isFalse);
    expect(third!.composite!.outer == first!.composite!.outer, isFalse);
  });

  test('request area cap follows the selected generation size tier', () async {
    final config = I2IConfig()..setImage(quadrantPng(2000, 3000));
    config.setMask(maskPngWithWhiteRect(2000, 3000, 900, 1400, 200, 200), []);
    final normal = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(normal!.width * normal.height, lessThanOrEqualTo(areaCapNormal));

    PrepareI2iRequestUseCase.clearCache();
    final large = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 1024,
      targetHeight: 1536,
    );
    expect(large!.width * large.height, lessThanOrEqualTo(areaCapLarge));
    expect(
        large.width * large.height, greaterThan(normal.width * normal.height));
  });
}
