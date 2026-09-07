import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/use_cases/pica_lanczos3.dart';

/// Immutable request artifact produced by [NovelAiImg2ImgNormalizer].
class NovelAiImg2ImgArtifact {
  final String imageB64;
  final int width;
  final int height;

  /// SHA-256 of the exact PNG bytes represented by [imageB64].
  final String contentIdentity;

  const NovelAiImg2ImgArtifact({
    required this.imageB64,
    required this.width,
    required this.height,
    required this.contentIdentity,
  });
}

/// Produces the immutable RGBA PNG NovelAI's browser img2img preparation
/// would place on its request canvas.
class NovelAiImg2ImgNormalizer {
  const NovelAiImg2ImgNormalizer._();

  static NovelAiImg2ImgArtifact normalize({
    required Uint8List imageBytes,
    required int targetWidth,
    required int targetHeight,
    required bool transparentBackground,
  }) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      throw const FormatException('Failed to decode img2img base image.');
    }
    final oriented = img.bakeOrientation(decoded);
    final pngFastPath = img.PngDecoder().isValidFile(imageBytes);
    var pixels = oriented;
    // The website decodes PNG bytes directly before removing carrier alpha.
    // A Canvas round-trip first can irreversibly change RGB at alpha 254.
    if (pngFastPath &&
        pixels.width * pixels.height <= 0x1000000 &&
        _hasStealthPngComp(pixels)) {
      pixels = _removeStealthCarrierAlpha(pixels);
    }
    pixels = _canvasRoundTrip(pixels);
    if (!pngFastPath && _hasStealthPngComp(pixels)) {
      pixels = _removeStealthCarrierAlpha(pixels);
    }
    if (pixels.width != targetWidth || pixels.height != targetHeight) {
      pixels = picaLanczos3Resize(
        pixels,
        width: targetWidth,
        height: targetHeight,
      );
      pixels = _canvasRoundTrip(pixels);
    }
    final requestImage =
        transparentBackground ? pixels : _compositeOntoWhite(pixels);
    final pngBytes = Uint8List.fromList(img.encodePng(requestImage));
    return NovelAiImg2ImgArtifact(
      imageB64: base64Encode(pngBytes),
      width: requestImage.width,
      height: requestImage.height,
      contentIdentity: sha256.convert(pngBytes).toString(),
    );
  }

  static img.Image _canvasRoundTrip(img.Image source) {
    final output = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 4,
    );
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final pixel = source.getPixel(x, y);
        final alpha = pixel.a.toInt();
        output.setPixelRgba(
          x,
          y,
          _canvasChannel(pixel.r.toInt(), alpha),
          _canvasChannel(pixel.g.toInt(), alpha),
          _canvasChannel(pixel.b.toInt(), alpha),
          alpha,
        );
      }
    }
    return output;
  }

  static final Uint8List _canvasChannels = _buildCanvasChannels();

  static int _canvasChannel(int channel, int alpha) =>
      _canvasChannels[(alpha << 8) | channel];

  static Uint8List _buildCanvasChannels() {
    final result = Uint8List(256 * 256);
    final float = Float32List(1);
    double f32(double value) {
      float[0] = value;
      return float[0];
    }

    // Canvas uses normalized float32 arithmetic and nearest-even conversion.
    // Integer division with round() disagrees at some transparent boundaries.
    final unit = f32(1 / 255);
    for (var alpha = 1; alpha < 256; alpha++) {
      final reciprocal = f32(1 / f32(alpha * unit));
      for (var channel = 0; channel < 256; channel++) {
        final premultiplied = (channel * alpha + 127) ~/ 255;
        final value = f32(f32(f32(premultiplied * unit) * reciprocal) * 255);
        final lower = value.floor();
        final rounded = value - lower == 0.5
            ? (lower.isEven ? lower : lower + 1)
            : value.round();
        result[(alpha << 8) | channel] = rounded.clamp(0, 255);
      }
    }
    return result;
  }

  static bool _hasStealthPngComp(img.Image image) {
    final magic = ascii.encode('stealth_pngcomp');
    if (image.width * image.height < magic.length * 8) return false;
    for (var byteIndex = 0; byteIndex < magic.length; byteIndex++) {
      var value = 0;
      for (var bit = 0; bit < 8; bit++) {
        final bitIndex = byteIndex * 8 + bit;
        final x = bitIndex ~/ image.height;
        final y = bitIndex % image.height;
        value |= (image.getPixel(x, y).a.toInt() & 1) << (7 - bit);
      }
      if (value != magic[byteIndex]) return false;
    }
    return true;
  }

  static img.Image _removeStealthCarrierAlpha(img.Image source) {
    final output = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 4,
    );
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final pixel = source.getPixel(x, y);
        final alpha = switch (pixel.a.toInt()) {
          254 => 255,
          1 => 0,
          final value => value,
        };
        output.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, alpha);
      }
    }
    return output;
  }

  static img.Image _compositeOntoWhite(img.Image source) {
    final output = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 4,
    );
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final pixel = source.getPixel(x, y);
        final alpha = pixel.a.toInt();
        output.setPixelRgba(
          x,
          y,
          _overWhite(pixel.r.toInt(), alpha),
          _overWhite(pixel.g.toInt(), alpha),
          _overWhite(pixel.b.toInt(), alpha),
          255,
        );
      }
    }
    return output;
  }

  static int _overWhite(int channel, int alpha) =>
      (channel * alpha / 255).round() + 255 - alpha;
}
