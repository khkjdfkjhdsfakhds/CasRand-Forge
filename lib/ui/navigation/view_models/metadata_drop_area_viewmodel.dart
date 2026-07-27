import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';

class MetadataDropAreaViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I();
  ParamConfig get config => payloadConfig.paramConfig;

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

  void setModel(BuildContext context, String model) {
    payloadConfig.fixedProfile.paramConfig.model = model;
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
}
