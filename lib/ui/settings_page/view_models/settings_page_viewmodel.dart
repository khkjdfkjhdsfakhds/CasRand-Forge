import 'dart:convert';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/settings.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

class SettingsPageViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I();
  ConfigService get configService => GetIt.I();

  SettingsPageViewmodel();

  Settings get settings {
    return payloadConfig.settings;
  }

  /// Re-reads settings-backed state (e.g. after returning from a sub-page).
  void refresh() {
    notifyListeners();
  }

  void setApiKey(String value) {
    payloadConfig.settings.apiKey = value;
    notifyListeners();
  }

  void setRememberSequentialProgress(bool? value) {
    if (value == null) return;
    payloadConfig.settings.rememberSequentialProgress = value;
    notifyListeners();
  }

  void setEraseMetadataEnabled(bool? value) {
    if (value == null) return;
    payloadConfig.settings.metadataEraseEnabled = value;
    notifyListeners();
  }

  void setCustomMetadataEnabled(bool? value) {
    if (value == null) return;
    payloadConfig.settings.customMetadataEnabled = value;
    notifyListeners();
  }

  void setCustomMetadataContent(String value) {
    payloadConfig.settings.customMetadataContent = value;
    notifyListeners();
  }

  void pickOutputFolderPath() async {
    final pickResult = await FilePicker.platform.getDirectoryPath();
    if (pickResult == null) return;
    payloadConfig.settings.outputFolderPath = pickResult;
    notifyListeners();
  }

  void setProxy(String value) {
    bool isValidProxy(String input) {
      if (input == '') return true;
      final ipPortRegex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}:\d{1,5}$');
      if (!ipPortRegex.hasMatch(value)) return false;
      return true;
    }

    if (!isValidProxy(value)) return;
    payloadConfig.settings.proxy = value;
    notifyListeners();
  }

  void loadJsonConfig(BuildContext context) async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return;
    try {
      var fileContent = utf8.decode(result.files.single.bytes!);
      Map<String, dynamic> jsonData = json.decode(fileContent);
      payloadConfig.loadJson(jsonData);
      if (!context.mounted) return;
      showInfoBar(context, '${tr('info_import_file')}${tr('succeed')}');
    } catch (error) {
      if (!context.mounted) return;
      showErrorBar(context,
          '${tr('info_import_file')}${tr('failed')}: ${error.toString()}');
    }
  }

  void setFileNamePrefixKey(String value) {
    payloadConfig.settings.fileNamePrefixKey = value;
    notifyListeners();
  }

  void saveJsonConfig() {
    final configJson = payloadConfig.toJson();
    final filename =
        'nai-generator-config-${FileService().generateRandomString()}.json';
    FileService().saveStringToFile(
      json.encode(configJson),
      filename,
    );
  }

  void setThemeMode(String value, BuildContext context) {
    payloadConfig.settings.themeMode = value;
    AdaptiveTheme.of(context).setThemeMode(stringToThemeMode[value]!);
    notifyListeners();
  }

  void notify() => notifyListeners();

  void saveCurrentConfig() {
    configService.saveConfig(payloadConfig.toJson());
  }

  Future<bool> restoreInitialSettings(
    BuildContext context, {
    required bool backupCurrent,
  }) async {
    try {
      if (backupCurrent) {
        await configService.saveNewConfig(
          payloadConfig.toJson(),
          title: tr('pre_restore_backup'),
        );
      }

      final defaultJson = json.decode(await configService.loadDefaultConfig())
          as Map<String, dynamic>;
      final initialConfig = PayloadConfig.fromJson(defaultJson);
      await configService.saveNewConfig(
        initialConfig.toJson(),
        title: tr('initial_settings_config_name'),
        makeCurrent: true,
      );

      payloadConfig.loadJson(initialConfig.toJson());
      payloadConfig.resetTransientConfigs();
      if (!context.mounted) return true;
      AdaptiveTheme.maybeOf(context)?.setThemeMode(settings.theme);
      await context.deleteSaveLocale();
      if (!context.mounted) return true;
      await context.resetLocale();
      if (!context.mounted) return true;
      notifyListeners();
      showInfoBar(context, tr('restore_initial_settings_success'));
      return true;
    } catch (error) {
      if (!context.mounted) return false;
      showErrorBar(
        context,
        '${tr('restore_initial_settings_failed')}: ${error.toString()}',
      );
      return false;
    }
  }
}
