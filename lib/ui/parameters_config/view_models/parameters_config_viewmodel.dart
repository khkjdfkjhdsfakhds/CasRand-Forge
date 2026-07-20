import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

class ParametersConfigViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I();
  ParamConfig get config => payloadConfig.paramConfig;

  ParametersConfigViewmodel();

  setSteps(double value) {
    config.steps = value.toInt();
    notifyListeners();
  }

  setScale(double value) {
    config.scale = value;
    notifyListeners();
  }

  setCfgRescale(double value) {
    config.cfgRescale = value;
    notifyListeners();
  }

  setSampler(String value) {
    config.sampler = value;
    config.clearImportedSamplerOverrides();
    notifyListeners();
  }

  setNoiseScheduler(String value) {
    config.noiseSchedule = value;
    config.clearImportedSamplerOverrides();
    notifyListeners();
  }

  setSm(bool value) {
    config.sm = value;
    notifyListeners();
  }

  setSmDyn(bool value) {
    config.smDyn = value;
    notifyListeners();
  }

  setVarietyPlus(bool value) {
    config.varietyPlus = value;
    notifyListeners();
  }

  setNegativePrompt(String value) {
    payloadConfig.setNegativePromptFromString(value);
    notifyListeners();
  }

  void setModel(String value) {
    config.model = value;
    config.clearImportedSamplerOverrides();
    notifyListeners();
  }

  bool get isV4 => config.model.contains('-4-');

  void setLegacyUc(bool? value) {
    if (value == null) return;
    config.legacyUc = value;
    notifyListeners();
  }

  void loadAllMetadata(
    BuildContext context,
    Map<String, dynamic> commentData,
    String? prompt,
    String? model,
  ) {
    int loadedCount = payloadConfig.loadParamJson(commentData);
    if (prompt != null) {
      payloadConfig.overridePrompt = prompt;
      payloadConfig.useOverridePrompt = true;
      loadedCount++;
    }
    if (model != null) {
      payloadConfig.paramConfig.model = model;
      loadedCount++;
    }
    notifyListeners();
    showInfoBar(
        context,
        tr(
          'loaded_parameters_count',
          namedArgs: {'num': loadedCount.toString()},
        ));
  }

  void loadSingleImageMetadata(
      BuildContext context, Map<String, dynamic> commentData, String key) {
    final loadedCount = payloadConfig.loadParamJson(commentData);
    if (loadedCount == 0) return;
    notifyListeners();
    showInfoBar(
        context,
        tr(
          'pasted_parameter',
          namedArgs: {'parameter_name': key},
        ));
  }

  void setOverridePrompt(BuildContext context, String? prompt) {
    if (prompt == null) return;
    payloadConfig.overridePrompt = prompt;
    payloadConfig.useOverridePrompt = true;
    notifyListeners();
    showInfoBar(
        context,
        tr(
          'pasted_parameter',
          namedArgs: {'parameter_name': tr('prompt')},
        ));
  }
}
