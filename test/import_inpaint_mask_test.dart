import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/use_cases/import_inpaint_mask.dart';

Uint8List encode(img.Image image) => Uint8List.fromList(img.encodePng(image));

img.Image decode(Uint8List bytes) => img.decodePng(bytes)!;

void main() {
  test('automatic mode prefers meaningful alpha transparency', () {
    final source = img.Image(width: 4, height: 4, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(0, 0, 0, 0));
    source.setPixelRgba(1, 1, 255, 255, 255, 255);
    final bytes = encode(source);

    final analysis = analyzeInpaintMask(bytes);
    final result = renderInpaintMask(
      sourceBytes: bytes,
      targetWidth: 4,
      targetHeight: 4,
    );

    expect(analysis.hasTransparency, isTrue);
    expect(analysis.automaticChannel, InpaintMaskChannel.alpha);
    expect(result.resolvedChannel, InpaintMaskChannel.alpha);
    expect(result.selectedPixels, 1);
    expect(decode(result.pngBytes).getPixel(1, 1).r, 255);
  });

  test('opaque grayscale masks use luminance and support inversion', () {
    final source = img.Image(width: 2, height: 1, numChannels: 3)
      ..setPixelRgb(0, 0, 0, 0, 0)
      ..setPixelRgb(1, 0, 255, 255, 255);
    final bytes = encode(source);

    final normal = renderInpaintMask(
      sourceBytes: bytes,
      targetWidth: 2,
      targetHeight: 1,
      threshold: 128,
    );
    final inverted = renderInpaintMask(
      sourceBytes: bytes,
      targetWidth: 2,
      targetHeight: 1,
      threshold: 128,
      invert: true,
    );

    expect(normal.resolvedChannel, InpaintMaskChannel.luminance);
    expect(decode(normal.pngBytes).getPixel(0, 0).r, 0);
    expect(decode(normal.pngBytes).getPixel(1, 0).r, 255);
    expect(decode(inverted.pngBytes).getPixel(0, 0).r, 255);
    expect(decode(inverted.pngBytes).getPixel(1, 0).r, 0);
  });

  test('color conversion uses perceptual luminance', () {
    final source = img.Image(width: 2, height: 1, numChannels: 3)
      ..setPixelRgb(0, 0, 0, 180, 0)
      ..setPixelRgb(1, 0, 0, 0, 180);
    final result = renderInpaintMask(
      sourceBytes: encode(source),
      targetWidth: 2,
      targetHeight: 1,
      channel: InpaintMaskChannel.luminance,
      threshold: 100,
    );
    final output = decode(result.pngBytes);

    expect(output.getPixel(0, 0).r, 255,
        reason: 'green is perceptually bright');
    expect(output.getPixel(1, 0).r, 0,
        reason: 'blue stays below the threshold');
  });

  test('rendering resizes to the base image dimensions', () {
    final source = img.Image(width: 2, height: 3, numChannels: 3);
    img.fill(source, color: img.ColorRgb8(255, 255, 255));
    final result = renderInpaintMask(
      sourceBytes: encode(source),
      targetWidth: 8,
      targetHeight: 5,
    );
    final output = decode(result.pngBytes);

    expect(output.width, 8);
    expect(output.height, 5);
    expect(result.selectedPixels, 40);
  });

  test('merge unions normalized repaint regions', () {
    final first = img.Image(width: 3, height: 1, numChannels: 3)
      ..setPixelRgb(0, 0, 255, 255, 255);
    final second = img.Image(width: 3, height: 1, numChannels: 3)
      ..setPixelRgb(2, 0, 255, 255, 255);
    final merged = decode(
      mergeInpaintMasks(
        existingMaskBytes: encode(first),
        importedMaskBytes: encode(second),
        targetWidth: 3,
        targetHeight: 1,
      ),
    );

    expect(merged.getPixel(0, 0).r, 255);
    expect(merged.getPixel(1, 0).r, 0);
    expect(merged.getPixel(2, 0).r, 255);
  });
}
