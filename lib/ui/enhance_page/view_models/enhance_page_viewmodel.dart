import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:nai_casrand/data/models/enhance_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class EnhancePageViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  EnhanceConfig get config => payloadConfig.enhanceConfig;
  bool _lastImportActivatedFixedMode = false;
  bool _disposed = false;

  bool takeLastImportActivatedFixedMode() {
    final value = _lastImportActivatedFixedMode;
    _lastImportActivatedFixedMode = false;
    return value;
  }

  Future<bool> pickAndSetImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return false;
    return loadImageBytes(await picked.readAsBytes());
  }

  Future<bool> loadImageBytes(Uint8List bytes) async {
    try {
      final source = config;
      source.setImage(bytes);
      final revision = source.imageRevision;
      _lastImportActivatedFixedMode = false;
      if (GetIt.I.isRegistered<GenerationPageViewmodel>()) {
        GetIt.I<GenerationPageViewmodel>().clearEnhanceResult();
      }
      notifyListeners();
      await _tryImportMetadata(bytes, source: source, revision: revision);
      if (!_isCurrentSource(source, revision)) return false;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isCurrentSource(EnhanceConfig source, int revision) =>
      !_disposed &&
      identical(config, source) &&
      source.imageRevision == revision;

  Future<void> _tryImportMetadata(
    Uint8List bytes, {
    required EnhanceConfig source,
    required int revision,
  }) async {
    try {
      final metadataString =
          await ImageService().extractMetadataFromBytes(bytes);
      if (metadataString == null || !_isCurrentSource(source, revision)) return;
      final decodedOuter = json.decode(metadataString);
      if (decodedOuter is! Map<String, dynamic>) return;
      final rawComment = decodedOuter['Comment'];
      Map<String, dynamic> comment = {};
      if (rawComment is String) {
        final decodedComment = json.decode(rawComment);
        if (decodedComment is Map<String, dynamic>) {
          comment = decodedComment;
        }
      } else if (rawComment is Map<String, dynamic>) {
        comment = rawComment;
      }
      final rawDescription = decodedOuter['Description'];
      final modelSource = decodedOuter['Source']?.toString() ?? '';
      if (comment.isEmpty && rawDescription is! String) return;
      payloadConfig.importMetadataToFixedProfile(
        comment,
        prompt: rawDescription is String ? rawDescription : null,
        model: modelFromSource(modelSource),
      );
      _lastImportActivatedFixedMode = true;
    } catch (_) {
      // The image remains usable even if its embedded metadata is malformed.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void removeImage() {
    _lastImportActivatedFixedMode = false;
    config.removeImage();
    if (GetIt.I.isRegistered<GenerationPageViewmodel>()) {
      GetIt.I<GenerationPageViewmodel>().clearEnhanceResult();
    }
    notifyListeners();
  }

  /// Whether the Img2Img base image can be pulled over as the source.
  bool get canUseI2iBaseImage => payloadConfig.i2iConfig.hasImage;

  Future<void> useI2iBaseImage() async {
    final bytes = payloadConfig.i2iConfig.imageBytes;
    if (bytes == null) return;
    await loadImageBytes(bytes);
  }

  List<double> get availableScales => config.availableScales;

  GenerationSize targetSizeFor(double scale) => config.targetSizeFor(scale);

  GenerationSize get targetSize => config.targetSize;

  EnhancePreset get preset => config.preset;

  void setScale(double value) {
    config.setScale(value);
    notifyListeners();
  }

  void setPresetIndex(int value) {
    config.setPresetIndex(value);
    notifyListeners();
  }

  void setShowIndividualSettings(bool value) {
    config.setShowIndividualSettings(value);
    notifyListeners();
  }

  void setStrength(double value) {
    config.setIndividualStrength(value);
    notifyListeners();
  }

  void setNoise(double value) {
    config.setIndividualNoise(value);
    notifyListeners();
  }

  /// Estimated Anlas for one Enhance run at the current settings, or null
  /// without a source image. Enhance is a plain img2img request, so the
  /// generation cost model applies as-is.
  AnlasCost? estimateCost() {
    if (!config.hasImage) return null;
    if (!payloadConfig.settings.subscriptionStatusKnown) return null;
    final paramConfig = payloadConfig.paramConfig;
    final target = targetSize;
    final smActive = !paramConfig.model.contains('diffusion-4') &&
        !paramConfig.model.contains('diffusion-5');
    return estimateAnlasCost(
      width: target.width,
      height: target.height,
      steps: paramConfig.steps,
      action: 'img2img',
      strength: config.strength,
      sm: smActive && paramConfig.sm,
      smDyn: smActive && paramConfig.smDyn,
      tier: payloadConfig.settings.subscriptionTier,
      subscriptionActive: payloadConfig.settings.subscriptionActive,
      model: paramConfig.model,
      opusUsageAvailable: payloadConfig.settings.opusUsageAvailable,
    );
  }
}
