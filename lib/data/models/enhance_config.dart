import 'package:nai_casrand/data/use_cases/enhance_request_options.dart';

import 'package:flutter/foundation.dart';
import 'package:nai_casrand/data/models/displayed_image_size.dart';
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
/// while its exact target is permitted by the website and its area cap, so a
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
  int _imageRevision = 0;
  int get imageRevision => _imageRevision;

  /// Magnification applied to the source image size.
  double scale;
  bool maxSelected = false;

  bool canUseMax(String model) {
    if (!hasImage ||
        width <= 0 ||
        height <= 0 ||
        !EnhanceRequestOptions.supportsMax(model) ||
        width * height >= 0.8 * officialEnhanceMaxPixels) {
      return false;
    }
    // The website checks the source area here, before final API alignment.
    try {
      EnhanceRequestOptions.costSize(width, height);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  bool usesMax(String model) => maxSelected && canUseMax(model);

  GenerationSize outputSize(String model) => usesMax(model)
      ? EnhanceRequestOptions.outputSize(width, height)
      : EnhanceRequestOptions.apiSize(targetSize.width, targetSize.height);

  GenerationSize requestSize(String model) => usesMax(model)
      ? GenerationSize(width: width, height: height)
      : targetSize;

  GenerationSize costSize(String model) => usesMax(model)
      ? EnhanceRequestOptions.costSize(width, height)
      : EnhanceRequestOptions.apiSize(targetSize.width, targetSize.height);

  void selectMax() {
    maxSelected = true;
    notifyListeners();
  }

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

  /// Conditioning uses the exact scaled sides. The final API request and
  /// displayed output use 64-pixel alignment after image normalization.
  GenerationSize targetSizeFor(double magnification) => GenerationSize(
        width: (magnification * width).floor(),
        height: (magnification * height).floor(),
      );

  GenerationSize get targetSize => targetSizeFor(scale);

  List<double> get availableScales {
    if (!hasImage) return const [];
    if ((width == 832 && height == 1216) || (width == 1216 && height == 832)) {
      return const [1.0, 1.5];
    }
    return enhanceScaleOptions.where((option) {
      final scaledWidth = width * option;
      final scaledHeight = height * option;
      return scaledWidth > 0 &&
          scaledHeight > 0 &&
          scaledWidth % 64 == 0 &&
          scaledHeight % 64 == 0 &&
          scaledWidth * scaledHeight <= officialEnhanceMaxPixels;
    }).toList(growable: false);
  }

  void setImage(Uint8List bytes) {
    final size = displayedImageSize(bytes);
    setPreparedImage(bytes, width: size.width, height: size.height);
  }

  void setPreparedImage(
    Uint8List bytes, {
    required int width,
    required int height,
  }) {
    maxSelected = false;
    this.width = width;
    this.height = height;
    _imageBytes = bytes;
    // Like the official panel, a newly imported size starts at the largest
    // valid magnification. The choice remains user-adjustable afterwards.
    final options = availableScales;
    if (options.isNotEmpty) {
      scale = options.last;
    }
    _imageRevision++;
    notifyListeners();
  }

  void removeImage() {
    _imageBytes = null;
    width = 0;
    height = 0;
    _imageRevision++;
    notifyListeners();
  }

  void setScale(double value) {
    maxSelected = false;
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
