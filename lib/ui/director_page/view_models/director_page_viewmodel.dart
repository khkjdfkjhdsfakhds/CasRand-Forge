import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';

class DirectorPageViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  DirectorToolConfig get config => payloadConfig.directorToolConfig;

  Future<bool> pickAndSetImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return false;
    config.setImage(await picked.readAsBytes());
    notifyListeners();
    return true;
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

  /// Reuses the Img2Img base image as the Director Tools source.
  bool get canUseBaseImage => payloadConfig.i2iConfig.hasImage;

  void useBaseImage() {
    final bytes = payloadConfig.i2iConfig.imageBytes;
    if (bytes == null) return;
    config.setImage(bytes);
    notifyListeners();
  }

  void removeImage() {
    config.removeImage();
    notifyListeners();
  }

  void setTool(String type) {
    config.setType(type);
    notifyListeners();
  }

  void toggleEmotion(String emotion, bool selected) {
    config.toggleEmotion(emotion, selected);
    notifyListeners();
  }

  void setDefry(int value) {
    config.setDefry(value);
    notifyListeners();
  }

  void setOverrideEnabled(bool value) {
    config.setOverrideEnabled(value);
    notifyListeners();
  }

  void setOverridePrompt(String value) {
    config.setOverridePrompt(value);
    notifyListeners();
  }

  /// Anlas the currently selected tool would consume, or null without a source.
  int? get currentCost => costFor(config.type);

  /// Anlas [tool] would consume for the loaded source image.
  int? costFor(String tool) {
    if (!config.hasImage) return null;
    return estimateDirectorToolAnlas(
      tool: tool,
      width: config.width,
      height: config.height,
    );
  }
}
