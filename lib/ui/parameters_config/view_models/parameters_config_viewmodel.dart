import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';

class ParametersConfigViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I();
  ParamConfig get config => payloadConfig.paramConfig;

  ParametersConfigViewmodel();

  setSteps(double value) {
    config.steps = value.toInt();
    notifyListeners();
  }

  void setStepsFromText(String value) {
    final parsedValue = int.tryParse(value);
    if (parsedValue == null || parsedValue < 0 || parsedValue > 50) return;
    config.steps = parsedValue;
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

  void setModelFromMetadata(BuildContext context, String value) {
    payloadConfig.fixedProfile.paramConfig.model = value;
    payloadConfig.promptMode = PromptMode.fixed;
    notifyListeners();
    showFixedModeImportNotice(
      context,
      tr(
        'pasted_parameter',
        namedArgs: {'parameter_name': tr('generation_model')},
      ),
    );
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
    final loadedCount = payloadConfig.importMetadataToFixedProfile(
      commentData,
      prompt: prompt,
      model: model,
    );
    notifyListeners();
    showFixedModeImportNotice(
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
    showFixedModeImportNotice(
        context,
        tr(
          'pasted_parameter',
          namedArgs: {'parameter_name': key},
        ));
  }

  void setOverridePrompt(BuildContext context, String? prompt) {
    if (prompt == null) return;
    payloadConfig.fixedProfile.rootPromptConfig =
        PayloadConfig.fixedPromptConfig(prompt);
    payloadConfig.promptMode = PromptMode.fixed;
    notifyListeners();
    showFixedModeImportNotice(
        context,
        tr(
          'pasted_parameter',
          namedArgs: {'parameter_name': tr('prompt')},
        ));
  }
}
