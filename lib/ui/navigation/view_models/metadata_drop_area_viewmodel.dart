import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/image_import_capabilities.dart';
import 'package:nai_casrand/data/models/metadata_import_options.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/ui/core/widgets/prompt_mode_switch_button.dart';

typedef PreciseReferenceImageImporter = Future<bool> Function(
  Uint8List bytes,
  String fileName,
);

class MetadataDropAreaViewmodel extends ChangeNotifier {
  final PayloadConfig? _payloadConfig;
  final ImageHandoffCoordinator? _imageHandoff;
  final NavigationRequest? _navigation;
  final PreciseReferenceImageImporter? _preciseReferenceImporter;

  MetadataDropAreaViewmodel({
    PayloadConfig? payloadConfig,
    ImageHandoffCoordinator? imageHandoff,
    NavigationRequest? navigation,
    PreciseReferenceImageImporter? preciseReferenceImporter,
  })  : _payloadConfig = payloadConfig,
        _imageHandoff = imageHandoff,
        _navigation = navigation,
        _preciseReferenceImporter = preciseReferenceImporter;

  PayloadConfig get payloadConfig => _payloadConfig ?? GetIt.I();
  ParamConfig get config => payloadConfig.paramConfig;
  ImageImportCapabilities get imageImportCapabilities =>
      ImageImportCapabilities.forModel(config.model);

  bool useAsImageToImage(Uint8List bytes) {
    final handoff = _imageHandoff ?? GetIt.I<ImageHandoffCoordinator>();
    return handoff.useAsBaseImage(bytes);
  }

  Future<bool> useAsVibeTransfer(Uint8List bytes, String fileName) async {
    final capabilities = imageImportCapabilities;
    if (!capabilities.supports(ImageImportAction.vibeTransfer)) return false;
    if (payloadConfig.addVibeImage(bytes, fileName) == 0) return false;
    (_navigation ?? GetIt.I<NavigationRequest>())
        .goTo(AppDestination.vibeReference);
    notifyListeners();
    return true;
  }

  Future<bool> useAsPreciseReference(
    Uint8List bytes,
    String fileName,
  ) async {
    if (!imageImportCapabilities.supports(ImageImportAction.preciseReference)) {
      return false;
    }
    final navigation = _navigation ?? GetIt.I<NavigationRequest>();
    final imported = await (_preciseReferenceImporter?.call(bytes, fileName) ??
        payloadConfig.addPreciseReferenceImage(bytes, fileName));
    if (!imported) return false;
    navigation.goTo(AppDestination.vibeReference);
    notifyListeners();
    return true;
  }

  MetadataImportAvailability metadataImportAvailability(
    Map<String, dynamic> metadata, {
    String? prompt,
    String? model,
  }) {
    return payloadConfig.metadataImportAvailability(
      metadata,
      prompt: prompt,
      model: model,
    );
  }

  int importSelectedMetadata(
    BuildContext context,
    Map<String, dynamic> metadata, {
    String? prompt,
    String? model,
    required MetadataImportOptions options,
  }) {
    final loadedCount = payloadConfig.importMetadataSelectively(
      metadata,
      prompt: prompt,
      model: model,
      options: options,
    );
    if (loadedCount == 0) return 0;
    notifyListeners();
    showFixedModeImportNotice(
      context,
      tr(
        'loaded_parameters_count',
        namedArgs: {'num': loadedCount.toString()},
      ),
    );
    return loadedCount;
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
