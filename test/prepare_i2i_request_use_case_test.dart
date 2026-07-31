import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/data/use_cases/import_inpaint_mask.dart';
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

  test('img2img plan preserves source bytes while requesting the target size',
      () async {
    final original = solidPng(500, 300, 200, 30, 30);
    final config = I2IConfig()..setImage(original);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan, isNotNull);
    expect(plan!.isInpaint, isFalse);
    expect(plan.width, 832);
    expect(plan.height, 1216);
    expect(plan.composite, isNull);
    expect(base64Decode(plan.imageB64), original);
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

  test('img2img plan preserves JPEG bytes instead of inflating them to PNG',
      () async {
    final source = img.Image(width: 832, height: 1216, numChannels: 3);
    img.fill(source, color: img.ColorRgb8(10, 200, 10));
    final original = Uint8List.fromList(img.encodeJpg(source, quality: 92));
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
    final requestMask = img.decodePng(base64Decode(plan.maskB64!))!;
    expect(requestMask.width, plan.width);
    expect(requestMask.height, plan.height);
    // The server mask is opaque black/white at request resolution.
    var white = 0;
    for (var y = 0; y < requestMask.height; y++) {
      for (var x = 0; x < requestMask.width; x++) {
        final pixel = requestMask.getPixel(x, y);
        expect(pixel.a, 255);
        if (pixel.r > 127) {
          expect(pixel.r, 255);
          white++;
        } else {
          expect(pixel.r, 0);
        }
      }
    }
    expect(white, greaterThan(0));

    final blendMask = img.decodePng(base64Decode(plan.blendMaskB64!))!;
    expect(blendMask.width, plan.width ~/ 8);
    expect(blendMask.height, plan.height ~/ 8);
    expect(blendMask.numChannels, 4);
    for (var y = 0; y < blendMask.height; y++) {
      for (var x = 0; x < blendMask.width; x++) {
        final pixel = blendMask.getPixel(x, y);
        expect(pixel.a, pixel.r > 127 ? 255 : 0);
      }
    }
  });

  test('manual Focus frame without a mask repaints its whole inner region',
      () async {
    final config = I2IConfig()..setImage(quadrantPng(1600, 2400));
    config.setMask(
      null,
      const [],
      focusFrame: const CropRect(x: 500, y: 800, w: 480, h: 640),
      minimumContextPx: 64,
    );

    expect(config.hasMask, isFalse);
    expect(config.hasInpaintSelection, isTrue);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );

    expect(plan, isNotNull);
    expect(plan!.isInpaint, isTrue);
    expect(plan.composite, isNotNull);
    expect(plan.summary, contains('manual'));
    final mask = img.decodePng(base64Decode(plan.maskB64!))!;
    final composite = plan.composite!;
    final outer = composite.outer;

    int requestX(int sourceX) => (composite.contentOffsetX +
        ((sourceX - outer.x) * composite.contentWidth / outer.w).floor());
    int requestY(int sourceY) => (composite.contentOffsetY +
        ((sourceY - outer.y) * composite.contentHeight / outer.h).floor());

    final innerX = outer.x + outer.w ~/ 2;
    final innerY = outer.y + outer.h ~/ 2;
    expect(
        mask.getPixel(requestX(innerX), requestY(innerY)).r, greaterThan(200));

    // The red Context Region is visible to the model but remains unpainted.
    final contextX = outer.x + 16;
    expect(
      mask.getPixel(requestX(contextX), requestY(innerY)).r,
      lessThan(50),
    );
  });

  test('autocrop stays inactive for a base image within the free size',
      () async {
    final config = I2IConfig()..setImage(quadrantPng(832, 1216));
    config.setMask(maskPngWithWhiteRect(832, 1216, 300, 500, 60, 60), []);
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.isInpaint, isTrue);
    expect(plan.composite, isNull);
    expect(plan.summary, contains('whole image'));
  });

  test('official 1/8 alpha mask survives import and request round trip',
      () async {
    final exported = img.Image(width: 104, height: 152, numChannels: 4);
    img.fillRect(
      exported,
      x1: 37,
      y1: 33,
      x2: 73,
      y2: 69,
      color: img.ColorRgba8(255, 255, 255, 255),
    );
    final imported = renderInpaintMask(
      sourceBytes: Uint8List.fromList(img.encodePng(exported)),
      targetWidth: 832,
      targetHeight: 1216,
    );
    final config = I2IConfig()..setImage(solidPng(832, 1216, 40, 50, 60));
    config.setMask(imported.pngBytes, []);

    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    final sent = img.decodePng(base64Decode(plan!.blendMaskB64!))!;

    expect(sent.width, exported.width);
    expect(sent.height, exported.height);
    for (var y = 0; y < exported.height; y++) {
      for (var x = 0; x < exported.width; x++) {
        final expected = exported.getPixel(x, y).a > 155;
        final actual = sent.getPixel(x, y);
        expect(actual.a > 155 && actual.r > 155, expected);
      }
    }
  });

  test('local composite uses the blend mask, not the opaque server mask',
      () async {
    final baseBytes = solidPng(512, 512, 20, 40, 60);
    final config = I2IConfig()..setImage(baseBytes);
    config.setMask(
      maskPngWithWhiteRect(512, 512, 240, 240, 32, 32),
      [],
    );
    final useCase = PrepareI2iRequestUseCase(config: config);
    final original = await useCase(targetWidth: 512, targetHeight: 512);
    final allWhite = img.Image(width: 512, height: 512, numChannels: 3);
    img.fill(allWhite, color: img.ColorRgb8(255, 255, 255));
    final plan = I2iRequestPlan(
      imageB64: original!.imageB64,
      maskB64: base64Encode(img.encodePng(allWhite)),
      blendMaskB64: original.blendMaskB64,
      width: original.width,
      height: original.height,
      strength: original.strength,
      noise: original.noise,
      addOriginalImage: original.addOriginalImage,
      composite: original.composite,
      summary: original.summary,
    );

    final resultBytes = await useCase.compositeInpaintResponse(
      responseBytes: solidPng(512, 512, 180, 180, 180),
      plan: plan,
    );
    final result = img.decodePng(resultBytes)!;
    final corner = result.getPixel(0, 0);
    expect((corner.r, corner.g, corner.b), (20, 40, 60));
    expect(result.getPixel(256, 256).r, greaterThan(100));
  });

  test('a manual Focus frame still applies to a small base image', () async {
    final config = I2IConfig()..setImage(quadrantPng(512, 512));
    config.setMask(
      maskPngWithWhiteRect(512, 512, 200, 200, 60, 60),
      [],
      focusFrame: const CropRect(x: 128, y: 128, w: 256, h: 256),
    );
    final plan = await PrepareI2iRequestUseCase(config: config)(
      targetWidth: 832,
      targetHeight: 1216,
    );
    expect(plan!.composite, isNotNull);
    expect(plan.summary, contains('manual'));
    expect(plan.composite!.scale, greaterThan(1.0));
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
      useCase.blendInpaintTileInto(
        canvas: canvas,
        responseBytes: solidPng(plan.width, plan.height, shade, shade, shade),
        plan: plan,
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
    final resultBytes = await useCase.compositeInpaintResponse(
      responseBytes: responseBytes,
      plan: plan,
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
    config.setMask(
      maskPngWithWhiteRect(512, 512, 200, 200, 60, 60),
      [],
      focusFrame: const CropRect(x: 128, y: 128, w: 256, h: 256),
    );
    final useCase = PrepareI2iRequestUseCase(config: config);
    final plan = await useCase(targetWidth: 832, targetHeight: 1216);
    final composite = plan!.composite!;
    expect(composite.isNativeScale, isFalse);

    final responseBytes = solidPng(plan.width, plan.height, 200, 0, 200);
    final resultBytes = await useCase.compositeInpaintResponse(
      responseBytes: responseBytes,
      plan: plan,
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
      () => useCase.compositeInpaintResponse(
        responseBytes: solidPng(64, 64, 0, 0, 0),
        plan: plan!,
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('whole-image infill uses the official feathered local composite',
      () async {
    final baseBytes = solidPng(512, 512, 20, 40, 60);
    final config = I2IConfig()..setImage(baseBytes);
    config.setMask(
      maskPngWithWhiteRect(512, 512, 232, 232, 48, 48),
      [],
    );
    final useCase = PrepareI2iRequestUseCase(config: config);
    final plan = await useCase(targetWidth: 512, targetHeight: 512);
    expect(plan!.composite, isNull);

    final resultBytes = await useCase.compositeInpaintResponse(
      responseBytes: solidPng(512, 512, 220, 10, 10),
      plan: plan,
    );
    final result = img.decodePng(resultBytes)!;

    final untouched = result.getPixel(0, 0);
    expect(untouched.r, 20);
    expect(untouched.g, 40);
    expect(untouched.b, 60);

    final painted = result.getPixel(256, 256);
    expect(painted.r, greaterThan(180));
    expect(painted.g, lessThan(20));

    final feathered = result.getPixel(180, 256);
    expect(feathered.r, greaterThan(20));
    expect(feathered.r, lessThan(220));
  });

  test('heavy plan data is cached while light request parameters stay fresh',
      () async {
    final config = I2IConfig()..setImage(quadrantPng(1600, 2400));
    config.setMask(maskPngWithWhiteRect(1600, 2400, 700, 1100, 120, 160), []);
    final useCase = PrepareI2iRequestUseCase(config: config);
    final first = await useCase(targetWidth: 832, targetHeight: 1216);
    final second = await useCase(targetWidth: 832, targetHeight: 1216);
    expect(second!.imageB64, first!.imageB64);
    expect(second.maskB64, first.maskB64);
    expect(second.composite!.outer, first.composite!.outer);

    final planRevision = config.planRevision;
    config.setStrength(0.42);
    config.setNoise(0.31);
    expect(config.planRevision, planRevision,
        reason: 'slider ticks must not invalidate image decoding or tiles');
    final retuned = await useCase(targetWidth: 832, targetHeight: 1216);
    expect(retuned!.imageB64, first.imageB64);
    expect(retuned.maskB64, first.maskB64);
    expect(retuned.strength, 0.42);
    expect(retuned.noise, 0.31);
    expect(retuned.summary, contains('strength 0.42'));

    // Changing the mask must invalidate the cached plan.
    config.setMask(maskPngWithWhiteRect(1600, 2400, 100, 100, 120, 160), []);
    final third = await useCase(targetWidth: 832, targetHeight: 1216);
    expect(third!.composite!.outer == first.composite!.outer, isFalse);
  });

  test('focus request area stays at the official 1 MP ceiling', () async {
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
    expect(large!.width * large.height, lessThanOrEqualTo(areaCapNormal));
    expect(large.width * large.height, normal.width * normal.height);
  });
}
