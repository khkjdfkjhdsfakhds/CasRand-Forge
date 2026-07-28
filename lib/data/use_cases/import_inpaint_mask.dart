import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Which source channel should be converted into the inpainting mask.
enum InpaintMaskChannel { automatic, alpha, luminance }

class InpaintMaskAnalysis {
  final int width;
  final int height;
  final bool hasAlphaChannel;
  final bool hasTransparency;
  final bool suggestedAlphaInvert;
  final bool suggestedLuminanceInvert;

  const InpaintMaskAnalysis({
    required this.width,
    required this.height,
    required this.hasAlphaChannel,
    required this.hasTransparency,
    required this.suggestedAlphaInvert,
    required this.suggestedLuminanceInvert,
  });

  InpaintMaskChannel get automaticChannel =>
      hasTransparency ? InpaintMaskChannel.alpha : InpaintMaskChannel.luminance;

  bool suggestedInvertFor(InpaintMaskChannel channel) {
    final resolved =
        channel == InpaintMaskChannel.automatic ? automaticChannel : channel;
    return resolved == InpaintMaskChannel.alpha
        ? suggestedAlphaInvert
        : suggestedLuminanceInvert;
  }
}

class InpaintMaskRenderResult {
  final Uint8List pngBytes;
  final int selectedPixels;
  final int totalPixels;
  final InpaintMaskChannel resolvedChannel;

  const InpaintMaskRenderResult({
    required this.pngBytes,
    required this.selectedPixels,
    required this.totalPixels,
    required this.resolvedChannel,
  });

  bool get isEmpty => selectedPixels == 0;
  double get selectedRatio =>
      totalPixels == 0 ? 0 : selectedPixels / totalPixels;
}

/// Inspects the source without changing it. Edge pixels are treated as the
/// likely background when suggesting whether a conventional black/white mask
/// should be inverted; the import UI always lets the user override this.
InpaintMaskAnalysis analyzeInpaintMask(
  Uint8List sourceBytes, {
  int threshold = 128,
}) {
  final source = img.decodeImage(sourceBytes);
  if (source == null || source.width <= 0 || source.height <= 0) {
    throw const FormatException('Unsupported or damaged mask image.');
  }

  var minAlpha = 255;
  if (source.hasAlpha) {
    for (final pixel in source) {
      final alpha = pixel.a.toInt();
      if (alpha < minAlpha) minAlpha = alpha;
      if (minAlpha == 0) break;
    }
  }

  return InpaintMaskAnalysis(
    width: source.width,
    height: source.height,
    hasAlphaChannel: source.hasAlpha,
    hasTransparency: source.hasAlpha && minAlpha < 255,
    suggestedAlphaInvert: _borderSuggestsInvert(
      source,
      channel: InpaintMaskChannel.alpha,
      threshold: threshold,
    ),
    suggestedLuminanceInvert: _borderSuggestsInvert(
      source,
      channel: InpaintMaskChannel.luminance,
      threshold: threshold,
    ),
  );
}

/// Converts common monochrome, grayscale, color or alpha-bearing images into
/// the one canonical form used by NovelAI requests: opaque black = keep,
/// opaque white = repaint, at exactly the base-image resolution.
InpaintMaskRenderResult renderInpaintMask({
  required Uint8List sourceBytes,
  required int targetWidth,
  required int targetHeight,
  InpaintMaskChannel channel = InpaintMaskChannel.automatic,
  int threshold = 128,
  bool invert = false,
}) {
  if (targetWidth <= 0 || targetHeight <= 0) {
    throw ArgumentError('The target mask size must be positive.');
  }
  final source = img.decodeImage(sourceBytes);
  if (source == null) {
    throw const FormatException('Unsupported or damaged mask image.');
  }

  final hasTransparency = source.hasAlpha && _hasTransparency(source);
  final resolvedChannel = channel == InpaintMaskChannel.automatic
      ? (hasTransparency
          ? InpaintMaskChannel.alpha
          : InpaintMaskChannel.luminance)
      : channel;

  final resized = source.width == targetWidth && source.height == targetHeight
      ? source
      : img.copyResize(
          source,
          width: targetWidth,
          height: targetHeight,
          // Masks carry categorical cells rather than photographic colour.
          // Nearest-neighbour preserves an exported 1/8 NovelAI mask exactly
          // when it is expanded to the editable image-resolution canvas.
          interpolation: img.Interpolation.nearest,
        );
  final output = img.Image(
    width: targetWidth,
    height: targetHeight,
    numChannels: 3,
  );
  var selected = 0;
  final clampedThreshold = threshold.clamp(1, 254);
  for (var y = 0; y < targetHeight; y++) {
    for (var x = 0; x < targetWidth; x++) {
      final value = _channelValue(resized.getPixel(x, y), resolvedChannel);
      final above = value >= clampedThreshold;
      final repaint = invert ? !above : above;
      if (repaint) {
        output.setPixelRgb(x, y, 255, 255, 255);
        selected++;
      }
    }
  }

  return InpaintMaskRenderResult(
    pngBytes: Uint8List.fromList(img.encodePng(output)),
    selectedPixels: selected,
    totalPixels: targetWidth * targetHeight,
    resolvedChannel: resolvedChannel,
  );
}

/// Unions two already-normalized masks. Inputs are defensively resized so old
/// transient state cannot produce a mask with coordinates from another image.
Uint8List mergeInpaintMasks({
  required Uint8List existingMaskBytes,
  required Uint8List importedMaskBytes,
  required int targetWidth,
  required int targetHeight,
}) {
  final existing = _decodeAndResizeMask(
    existingMaskBytes,
    targetWidth,
    targetHeight,
  );
  final imported = _decodeAndResizeMask(
    importedMaskBytes,
    targetWidth,
    targetHeight,
  );
  final output = img.Image(
    width: targetWidth,
    height: targetHeight,
    numChannels: 3,
  );
  for (var y = 0; y < targetHeight; y++) {
    for (var x = 0; x < targetWidth; x++) {
      if (existing.getPixel(x, y).r > 127 || imported.getPixel(x, y).r > 127) {
        output.setPixelRgb(x, y, 255, 255, 255);
      }
    }
  }
  return Uint8List.fromList(img.encodePng(output));
}

bool inpaintMaskHasSelection(Uint8List pngBytes) {
  final mask = img.decodePng(pngBytes) ?? img.decodeImage(pngBytes);
  if (mask == null) return false;
  for (final pixel in mask) {
    if (pixel.r > 127) return true;
  }
  return false;
}

bool _hasTransparency(img.Image image) {
  if (!image.hasAlpha) return false;
  for (final pixel in image) {
    if (pixel.a < 255) return true;
  }
  return false;
}

img.Image _decodeAndResizeMask(Uint8List bytes, int width, int height) {
  final decoded = img.decodePng(bytes) ?? img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Unsupported or damaged mask image.');
  }
  if (decoded.width == width && decoded.height == height) return decoded;
  return img.copyResize(
    decoded,
    width: width,
    height: height,
    interpolation: img.Interpolation.nearest,
  );
}

bool _borderSuggestsInvert(
  img.Image image, {
  required InpaintMaskChannel channel,
  required int threshold,
}) {
  if (channel == InpaintMaskChannel.alpha && !image.hasAlpha) return false;
  var light = 0;
  var total = 0;
  final clampedThreshold = threshold.clamp(1, 254);

  void sample(int x, int y) {
    total++;
    if (_channelValue(image.getPixel(x, y), channel) >= clampedThreshold) {
      light++;
    }
  }

  for (var x = 0; x < image.width; x++) {
    sample(x, 0);
    if (image.height > 1) sample(x, image.height - 1);
  }
  for (var y = 1; y < image.height - 1; y++) {
    sample(0, y);
    if (image.width > 1) sample(image.width - 1, y);
  }
  return total > 0 && light * 2 > total;
}

int _channelValue(img.Pixel pixel, InpaintMaskChannel channel) {
  if (channel == InpaintMaskChannel.alpha) return pixel.a.toInt();
  final red = pixel.r.toDouble();
  final green = pixel.g.toDouble();
  final blue = pixel.b.toDouble();
  return (red * 0.2126 + green * 0.7152 + blue * 0.0722).round().clamp(0, 255);
}
