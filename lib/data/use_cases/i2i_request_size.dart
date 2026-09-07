import 'dart:math';

import 'package:nai_casrand/data/models/generation_size.dart';

/// Img2Img request-size modes. They are intentionally independent from the
/// text-to-image size list.
enum I2iSizeMode {
  /// Closest 64-pixel-grid size inside NovelAI's normal 1 MP window.
  automatic,

  /// Closest size to the imported image, allowed up to the generation limit.
  original,

  /// A user-entered size, normalized to the same grid and generation limit.
  manual,
}

const int novelAiSizeStep = 64;
const int novelAiNormalMaxPixels = 1024 * 1024;
const int novelAiGenerationMaxPixels = 3 * 1024 * 1024;

/// Finds the closest usable request size to [sourceWidth] × [sourceHeight].
///
/// Both sides are always multiples of 64. The result preserves the source
/// aspect ratio as closely as possible while never exceeding [maxPixels].
/// There is deliberately no per-side 1728 clamp: NovelAI's current frontend
/// validates the generation-wide 3 MP area limit.
GenerationSize closestI2iRequestSize({
  required int sourceWidth,
  required int sourceHeight,
  required int maxPixels,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0 || maxPixels < 64 * 64) {
    return const GenerationSize(width: 64, height: 64);
  }

  final directlySnapped = GenerationSize(
    width: _snapToStep(sourceWidth),
    height: _snapToStep(sourceHeight),
  );
  if (directlySnapped.width * directlySnapped.height <= maxPixels) {
    return directlySnapped;
  }

  final sourceArea = sourceWidth.toDouble() * sourceHeight;
  final scale = sourceArea > maxPixels ? sqrt(maxPixels / sourceArea) : 1.0;
  final targetWidth = sourceWidth * scale;
  final targetHeight = sourceHeight * scale;
  final sourceRatio = sourceWidth / sourceHeight;

  GenerationSize? best;
  var bestScore = double.infinity;
  final maxWidth = (maxPixels ~/ novelAiSizeStep) * novelAiSizeStep;

  for (var width = novelAiSizeStep;
      width <= maxWidth;
      width += novelAiSizeStep) {
    final maxHeightForWidth =
        ((maxPixels ~/ width) ~/ novelAiSizeStep) * novelAiSizeStep;
    if (maxHeightForWidth < novelAiSizeStep) continue;

    final heightCandidates = <int>{
      _snapToStep(targetHeight.round()),
      _snapToStep((width / sourceRatio).round()),
      maxHeightForWidth,
    };
    for (final rawHeight in heightCandidates) {
      final height =
          rawHeight.clamp(novelAiSizeStep, maxHeightForWidth).toInt();
      final widthError = (width - targetWidth) / targetWidth;
      final heightError = (height - targetHeight) / targetHeight;
      final ratioError = log((width / height) / sourceRatio);
      // Dimension proximity keeps the chosen area useful; the additional
      // ratio term avoids turning square or panoramic sources into a visibly
      // different shape merely to fill a few more pixels.
      final score = widthError * widthError +
          heightError * heightError +
          4 * ratioError * ratioError;
      if (score < bestScore) {
        bestScore = score;
        best = GenerationSize(width: width, height: height);
      }
    }
  }

  return best ?? const GenerationSize(width: 64, height: 64);
}

GenerationSize automaticI2iRequestSize(int width, int height) {
  return closestI2iRequestSize(
    sourceWidth: width,
    sourceHeight: height,
    maxPixels: novelAiNormalMaxPixels,
  );
}

GenerationSize originalI2iRequestSize(int width, int height) {
  return closestI2iRequestSize(
    sourceWidth: width,
    sourceHeight: height,
    maxPixels: novelAiGenerationMaxPixels,
  );
}

GenerationSize manualI2iRequestSize(int width, int height) {
  return closestI2iRequestSize(
    sourceWidth: width,
    sourceHeight: height,
    maxPixels: novelAiGenerationMaxPixels,
  );
}

int _snapToStep(int value) {
  return max(
    novelAiSizeStep,
    (value / novelAiSizeStep).round() * novelAiSizeStep,
  );
}
