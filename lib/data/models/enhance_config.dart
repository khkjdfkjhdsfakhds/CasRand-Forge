import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image_size_getter/image_size_getter.dart';
import 'package:nai_casrand/data/models/generation_size.dart';

/// Enhance magnitude presets (1-5), matching the official Enhance panel.
class EnhancePreset {
  final String labelKey;
  final double strength;
  final double noise;

  const EnhancePreset({
    required this.labelKey,
    required this.strength,
    required this.noise,
  });
}

const List<EnhancePreset> enhancePresets = [
  EnhancePreset(labelKey: 'enhance_preset_1', strength: 0.2, noise: 0),
  EnhancePreset(labelKey: 'enhance_preset_2', strength: 0.4, noise: 0),
  EnhancePreset(labelKey: 'enhance_preset_3', strength: 0.5, noise: 0),
  EnhancePreset(labelKey: 'enhance_preset_4', strength: 0.6, noise: 0),
  EnhancePreset(labelKey: 'enhance_preset_5', strength: 0.7, noise: 0.1),
];

/// Magnifications the official Enhance panel can offer. Which of them are
/// actually available depends on the source size: an option is shown only
/// while its 64-aligned target stays within the maximum request area, so a
/// large image may offer 1x only, a typical portrait 1x/1.5x, and a small
/// image all the way up to 2x.
const List<double> enhanceScaleOptions = [1.0, 1.5, 2.0];
const int officialEnhanceMaxPixels = 3 * 1024 * 1024;

/// State of the Enhance destination: its own source image (separate from the
/// Img2Img base image) plus the magnification and strength preset.
class EnhanceConfig with ChangeNotifier {
  Uint8List? _imageBytes;
  int width = 0;
  int height = 0;

  /// Magnification applied to the source image size.
  double scale;

  /// Index into [enhancePresets] for the strength/noise pair.
  int presetIndex;

  /// The official Enhance panel keeps Magnitude as the default control and
  /// exposes the underlying img2img values on demand.
  bool showIndividualSettings;
  double individualStrength;
  double individualNoise;

  EnhanceConfig({
    this.scale = 1.5,
    this.presetIndex = 2,
    this.showIndividualSettings = false,
    this.individualStrength = 0.5,
    this.individualNoise = 0,
  });

  Uint8List? get imageBytes => _imageBytes;
  bool get hasImage => _imageBytes != null;

  EnhancePreset get preset =>
      enhancePresets[presetIndex.clamp(0, enhancePresets.length - 1)];
  double get strength =>
      showIndividualSettings ? individualStrength : preset.strength;
  double get noise => showIndividualSettings ? individualNoise : preset.noise;

  /// Target size for a magnification: the scaled side rounded to the nearest
  /// multiple of 64, with a 64 floor.
  GenerationSize targetSizeFor(double magnification) {
    int snap(int value) => max(64, (value / 64).round() * 64);
    return GenerationSize(
      width: snap((magnification * width).round()),
      height: snap((magnification * height).round()),
    );
  }

  GenerationSize get targetSize => targetSizeFor(scale);

  /// Magnifications whose 64-aligned target still fits NovelAI's maximum
  /// request area.
  List<double> get availableScales {
    if (!hasImage) return const [];
    return enhanceScaleOptions.where((option) {
      final size = targetSizeFor(option);
      return size.width * size.height <= officialEnhanceMaxPixels;
    }).toList(growable: false);
  }

  void setImage(Uint8List bytes) {
    final size = ImageSizeGetter.getSize(MemoryInput(bytes));
    width = size.width;
    height = size.height;
    _imageBytes = bytes;
    // Like the official panel, a newly imported size starts at the largest
    // valid magnification. The choice remains user-adjustable afterwards.
    final options = availableScales;
    if (options.isNotEmpty) {
      scale = options.last;
    }
    notifyListeners();
  }

  void removeImage() {
    _imageBytes = null;
    width = 0;
    height = 0;
    notifyListeners();
  }

  void setScale(double value) {
    scale = value;
    notifyListeners();
  }

  void setPresetIndex(int value) {
    presetIndex = value.clamp(0, enhancePresets.length - 1);
    notifyListeners();
  }

  void setShowIndividualSettings(bool value) {
    if (value && !showIndividualSettings) {
      individualStrength = preset.strength;
      individualNoise = preset.noise;
    }
    showIndividualSettings = value;
    notifyListeners();
  }

  void setIndividualStrength(double value) {
    individualStrength = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setIndividualNoise(double value) {
    individualNoise = value.clamp(0.0, 0.99);
    notifyListeners();
  }
}
