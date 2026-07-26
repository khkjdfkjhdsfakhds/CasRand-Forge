import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';

class I2iPageViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  I2IConfig get config => payloadConfig.i2iConfig;
  ParamConfig get paramConfig => payloadConfig.paramConfig;

  Future<bool> pickAndSetImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return false;
    final bytes = await picked.readAsBytes();
    return loadImageBytes(bytes);
  }

  bool loadImageBytes(Uint8List bytes) {
    try {
      config.setImage(bytes);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  void removeImage() {
    config.removeImage();
    notifyListeners();
  }

  void setStrength(double value) {
    config.setStrength(double.parse(value.toStringAsFixed(2)));
    notifyListeners();
  }

  void setNoise(double value) {
    config.setNoise(double.parse(value.toStringAsFixed(2)));
    notifyListeners();
  }

  void setAddOriginalImage(bool value) {
    config.setAddOriginalImage(value);
    notifyListeners();
  }

  void setAutocropEnabled(bool value) {
    config.setAutocropEnabled(value);
    notifyListeners();
  }

  void setMask(Uint8List? maskBytes, List<MaskStroke> strokes) {
    if (maskBytes == null) {
      config.removeMask();
    } else {
      config.setMask(maskBytes, strokes);
    }
    notifyListeners();
  }

  void clearMask() {
    config.removeMask();
    notifyListeners();
  }

  /// The image size snapped to the 64-px grid (and NovelAI's limits), used by
  /// the "use image size" shortcut for plain img2img.
  GenerationSize get snappedImageSize {
    final width = _snapDimension(config.width);
    final height = _snapDimension(config.height);
    return GenerationSize(width: width, height: height);
  }

  int _snapDimension(int value) {
    final snapped = (value / 64).round() * 64;
    return max(64, min(maxRequestSide, snapped));
  }

  bool get paramSizeMatchesImage {
    if (!config.hasImage) return true;
    final sizes = paramConfig.sizes;
    final target = snappedImageSize;
    return sizes.length == 1 && sizes.first == target;
  }

  void applyImageSizeToParams() {
    if (!config.hasImage) return;
    paramConfig.sizes = [snappedImageSize];
    notifyListeners();
  }

  String get paramSizeText {
    return paramConfig.sizes
        .map((size) => '${size.width} × ${size.height}')
        .join(', ');
  }
}
