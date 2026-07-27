import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';

class I2iPageViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  I2IConfig get config => payloadConfig.i2iConfig;

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

  void setMask(
    Uint8List? maskBytes,
    List<MaskStroke> strokes, {
    CropRect? focusFrame,
  }) {
    if (maskBytes == null) {
      config.removeMask();
    } else {
      config.setMask(maskBytes, strokes);
      config.setManualFocusFrame(focusFrame);
    }
    notifyListeners();
  }

  void clearMask() {
    config.removeMask();
    notifyListeners();
  }

  void clearManualFocusFrame() {
    config.setManualFocusFrame(null);
    notifyListeners();
  }

  GenerationSize get automaticSize =>
      automaticI2iRequestSize(config.width, config.height);

  GenerationSize get originalSize =>
      originalI2iRequestSize(config.width, config.height);

  bool applyAutomaticSize() {
    if (!config.hasImage) return false;
    config.setRequestSize(automaticSize, mode: I2iSizeMode.automatic);
    notifyListeners();
    return true;
  }

  bool applyImageSizeToParams() {
    if (!config.hasImage) return false;
    config.setRequestSize(originalSize, mode: I2iSizeMode.original);
    notifyListeners();
    return true;
  }

  /// Sets the request size from hand-typed values, snapped to the 64-px grid
  /// within NovelAI's limits. Returns the size actually applied, or null for
  /// unparsable input.
  GenerationSize? applyManualRequestSize(String width, String height) {
    final parsedWidth = int.tryParse(width.trim());
    final parsedHeight = int.tryParse(height.trim());
    if (parsedWidth == null || parsedHeight == null) return null;
    if (parsedWidth <= 0 || parsedHeight <= 0) return null;
    final size = manualI2iRequestSize(parsedWidth, parsedHeight);
    config.setRequestSize(size, mode: I2iSizeMode.manual);
    notifyListeners();
    return size;
  }

  String get paramSizeText {
    final size = config.requestSize;
    return '${size.width} × ${size.height}';
  }

  I2iSizeMode get sizeMode => config.sizeMode;
}
