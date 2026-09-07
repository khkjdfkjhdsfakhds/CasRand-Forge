import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

img.Image solid(int width, int height, int alpha, [bool response = false]) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image,
      color: response
          ? img.ColorRgba8(220, 30, 40, alpha)
          : img.ColorRgba8(20, 100, 180, alpha));
  return image;
}

I2iRequestPlan plan(img.Image latent, {AutocropCompositeInfo? composite}) =>
    I2iRequestPlan(
      imageB64: '',
      maskB64: '',
      blendMaskB64: base64Encode(img.encodePng(latent)),
      width: latent.width * 8,
      height: latent.height * 8,
      strength: .7,
      noise: .2,
      addOriginalImage: false,
      composite: composite,
      summary: '',
    );

void main() {
  test('mask cut and add agrees with independent website alpha goldens', () {
    // Browser capture of deployed x/lEi (1052-61d45f60b6583648), 2026-09-07.
    // Records are base alpha, response alpha, effective feather alpha, RGBA.
    // Native Canvas uses byte premultiplication; allow RGB ±2 and alpha ±1,
    // separately from metadata (none of these synthetic fixtures contains it).
    const goldens = <List<int>>[
      [0, 0, 0, 0, 0, 0, 0],
      [0, 0, 124, 0, 0, 0, 0],
      [0, 0, 131, 0, 0, 0, 0],
      [0, 0, 255, 0, 0, 0, 0],
      [0, 128, 0, 0, 0, 0, 0],
      [0, 128, 124, 218, 29, 41, 62],
      [0, 128, 131, 220, 31, 39, 66],
      [0, 128, 255, 219, 30, 40, 128],
      [0, 255, 0, 0, 0, 0, 0],
      [0, 255, 124, 220, 31, 39, 124],
      [0, 255, 131, 220, 29, 41, 131],
      [0, 255, 255, 220, 30, 40, 255],
      [128, 0, 0, 20, 100, 179, 128],
      [128, 0, 124, 19, 100, 178, 66],
      [128, 0, 131, 21, 99, 181, 62],
      [128, 0, 255, 0, 0, 0, 0],
      [128, 128, 0, 20, 100, 179, 128],
      [128, 128, 124, 116, 66, 112, 128],
      [128, 128, 131, 124, 64, 108, 128],
      [128, 128, 255, 219, 30, 40, 128],
      [128, 255, 0, 20, 100, 179, 128],
      [128, 255, 124, 150, 55, 87, 190],
      [128, 255, 131, 156, 52, 86, 193],
      [128, 255, 255, 220, 30, 40, 255],
      [255, 0, 0, 20, 100, 180, 255],
      [255, 0, 124, 19, 99, 179, 131],
      [255, 0, 131, 21, 101, 181, 124],
      [255, 0, 255, 0, 0, 0, 0],
      [255, 128, 0, 20, 100, 180, 255],
      [255, 128, 124, 83, 77, 135, 193],
      [255, 128, 131, 90, 76, 132, 190],
      [255, 128, 255, 219, 30, 40, 128],
      [255, 255, 0, 20, 100, 180, 255],
      [255, 255, 124, 117, 66, 111, 255],
      [255, 255, 131, 123, 64, 109, 255],
      [255, 255, 255, 220, 30, 40, 255],
    ];
    final latent = img.Image(width: 64, height: 64, numChannels: 4);
    img.fillRect(latent,
        x1: 29,
        y1: 29,
        x2: 34,
        y2: 34,
        color: img.ColorRgba8(255, 255, 255, 255));
    final request = plan(latent);
    final useCase = PrepareI2iRequestUseCase(config: I2IConfig());
    // Dilation by four latent cells and two 41-pixel box passes put the
    // corresponding independent mask values at these fixed sample points.
    const sampleX = {0: 0, 124: 199, 131: 200, 255: 256};
    for (final baseAlpha in [0, 128, 255]) {
      for (final responseAlpha in [0, 128, 255]) {
        final canvas = solid(512, 512, baseAlpha);
        useCase.blendInpaintTileInto(
          canvas: canvas,
          responseBytes: Uint8List.fromList(
              img.encodePng(solid(512, 512, responseAlpha, true))),
          plan: request,
        );
        for (final row in goldens
            .where((row) => row[0] == baseAlpha && row[1] == responseAlpha)) {
          final pixel = canvas.getPixel(sampleX[row[2]]!, 256);
          expect(pixel.a, closeTo(row[6], 1), reason: '$row');
          if (row[2] == 0) {
            expect(pixel.toList(), [20, 100, 180, baseAlpha]);
          } else {
            for (var channel = 0; channel < 3; channel++) {
              expect(pixel[channel], closeTo(row[channel + 3], 2),
                  reason: '$row, channel $channel');
            }
          }
        }
      }
    }
  });

  test('Focus clipping, padding, scaling and overlapping tiles retain alpha',
      () async {
    final latent = img.Image(width: 8, height: 8, numChannels: 4);
    img.fill(latent, color: img.ColorRgba8(255, 255, 255, 255));
    final request = plan(latent,
        composite: const AutocropCompositeInfo(
          outer: CropRect(x: -8, y: 16, w: 32, h: 32),
          contentOffsetX: 8,
          contentOffsetY: 8,
          contentWidth: 48,
          contentHeight: 48,
          scale: 1.5,
        ));
    final useCase = PrepareI2iRequestUseCase(config: I2IConfig());
    var canvas = solid(64, 64, 255);
    for (final alpha in [128, 0, 255]) {
      canvas = await useCase.blendInpaintTileInBackground(
        canvas: canvas,
        responseBytes:
            Uint8List.fromList(img.encodePng(solid(64, 64, alpha, true))),
        plan: request,
      );
      expect(canvas.getPixel(8, 32).a, alpha);
      expect(canvas.getPixel(0, 32).a, alpha);
      expect(canvas.getPixel(24, 32).toList(), [20, 100, 180, 255]);
      expect(canvas.getPixel(8, 15).toList(), [20, 100, 180, 255]);
      expect(canvas.getPixel(8, 48).toList(), [20, 100, 180, 255]);
      expect(canvas.getPixel(8, 32).toList(),
          alpha == 0 ? [0, 0, 0, 0] : [220, 30, 40, alpha]);
    }
  });

  test('resizing Focus never mixes invisible response RGB into visible edges',
      () {
    final latent = img.Image(width: 8, height: 8, numChannels: 4);
    img.fill(latent, color: img.ColorRgba8(255, 255, 255, 255));
    final request = plan(latent,
        composite: const AutocropCompositeInfo(
          outer: CropRect(x: 8, y: 8, w: 32, h: 32),
          contentOffsetX: 8,
          contentOffsetY: 8,
          contentWidth: 48,
          contentHeight: 48,
          scale: 1.5,
        ));
    final response = solid(64, 64, 255, true);
    for (var y = 0; y < 64; y++) {
      for (var x = 31; x < 64; x++) {
        response.setPixelRgba(x, y, 0, 0, 255, 0);
      }
    }
    final canvas = solid(64, 64, 255);
    PrepareI2iRequestUseCase(config: I2IConfig()).blendInpaintTileInto(
      canvas: canvas,
      responseBytes: Uint8List.fromList(img.encodePng(response)),
      plan: request,
    );
    var semiTransparent = 0;
    for (var x = 8; x < 40; x++) {
      final pixel = canvas.getPixel(x, 20);
      if (pixel.a == 0) {
        expect(pixel.toList(), [0, 0, 0, 0]);
      } else {
        if (pixel.a < 255) semiTransparent++;
        expect(pixel.r, closeTo(220, 1));
        expect(pixel.g, closeTo(30, 1));
        expect(pixel.b, closeTo(40, 1));
      }
    }
    expect(semiTransparent, greaterThan(0));
  });
}
