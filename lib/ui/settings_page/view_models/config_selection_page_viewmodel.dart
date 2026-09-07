import 'dart:convert';

import 'package:adaptive_theme/adaptive_theme.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

class SelectedConfigFile {
  final String name;
  final List<int> bytes;

  const SelectedConfigFile({required this.name, required this.bytes});
}

class ConfigSelectionPageViewmodel extends ChangeNotifier {
  final Future<SelectedConfigFile?> Function() _pickConfigFile;

  ConfigService get configService => GetIt.I();
  PayloadConfig get payloadConfig => GetIt.I();
  Map<String, SavedConfigInfo> get configIndexes => configService.configIndex;

  ConfigSelectionPageViewmodel({
    Future<SelectedConfigFile?> Function()? pickConfigFile,
  }) : _pickConfigFile = pickConfigFile ?? _pickFile;

  static Future<SelectedConfigFile?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) throw const FormatException('Selected file is empty.');
    return SelectedConfigFile(name: file.name, bytes: bytes);
  }

  Future<void> deleteConfig(BuildContext context, String uuid) async {
    try {
      await configService.deleteConfigByUuid(uuid);
      notifyListeners();
    } catch (error) {
      if (context.mounted) showErrorBar(context, '$error');
    }
  }

  Future<void> saveCopyOfCurrentConfig(BuildContext context) async {
    try {
      final currentName = configIndexes[configService.currentUuid]!.title;
      await configService.saveNewConfig(
        payloadConfig.toJson(),
        title: '${tr('copied_config')}${tr('colon')}$currentName',
      );
      notifyListeners();
    } catch (error) {
      if (context.mounted) showErrorBar(context, '$error');
    }
  }

  Future<void> importConfigFromFile(BuildContext context) async {
    try {
      final result = await _pickConfigFile();
      if (result == null) return;
      final fileContent = utf8.decode(result.bytes);
      final jsonData = json.decode(fileContent) as Map<String, dynamic>;
      await configService.saveImportedConfig(
        jsonData,
        title: '${tr('imported_config')}${tr('colon')}${result.name}',
      );
      notifyListeners();
    } catch (error) {
      if (!context.mounted) return;
      showErrorBar(context,
          '${tr('info_import_file')}${tr('failed')}: ${error.toString()}');
    }
  }

  Future<void> loadSavedConfig(BuildContext context, String uuid) async {
    try {
      final selected = await configService.selectConfig(
        uuid,
        currentConfig: payloadConfig.toJson(),
      );
      payloadConfig.loadJson(selected);
      notifyListeners();
      if (context.mounted) {
        AdaptiveTheme.maybeOf(context)
            ?.setThemeMode(payloadConfig.settings.theme);
        showInfoBar(context, '${tr('info_load_saved_config')}${tr('succeed')}');
      }
    } catch (error) {
      if (context.mounted) showErrorBar(context, '$error');
    }
  }

  Future<void> saveConfigAsFile(BuildContext context, String uuid) async {
    try {
      final saved = configService.loadConfigByUuid(uuid);
      if (saved == null) {
        throw StateError('Saved configuration does not exist.');
      }
      final configJson = PayloadConfig.fromJson(saved).toShareableJson();
      final filename =
          'nai-generator-config-${FileService().generateRandomString()}.json';
      await FileService().saveStringToFile(
        json.encode(configJson),
        filename,
      );
    } catch (error) {
      if (context.mounted) showErrorBar(context, '$error');
    }
  }

  Future<void> setConfigName(String uuid, String title) async {
    await configService.renameConfigByUuid(uuid, title);
    notifyListeners();
  }
}
