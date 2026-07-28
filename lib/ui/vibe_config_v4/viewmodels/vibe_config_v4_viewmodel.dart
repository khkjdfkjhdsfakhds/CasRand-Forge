import 'package:flutter/foundation.dart';

import '../../../data/models/vibe_config_v4.dart';

class VibeConfigV4Viewmodel extends ChangeNotifier {
  final VibeConfigV4 config;
  final String model;
  final VoidCallback? onChanged;

  VibeConfigV4Viewmodel({
    required this.config,
    required this.model,
    this.onChanged,
  });

  String get fileName => config.fileName;
  Uint8List? get imageBytes => config.imageBytes;
  double get referenceStrength => config.referenceStrength;
  double get informationExtracted => config.informationExtracted;
  bool get encodingReady => config.encodingFor(model) != null;
  bool get canEncode => config.canEncode;

  void setReferenceStrength(double value) {
    config.referenceStrength = value.clamp(0.0, 1.0);
    _notifyChanged();
  }

  void setInformationExtracted(double value) {
    config.informationExtracted = value.clamp(0.0, 1.0);
    _notifyChanged();
  }

  void _notifyChanged() {
    notifyListeners();
    onChanged?.call();
  }
}
