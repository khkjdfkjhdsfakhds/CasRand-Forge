import 'dart:convert';
import 'dart:io';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/settings.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/proxy_detection_service.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';

class SettingsPageViewmodel extends ChangeNotifier {
  final ProxyDetectionService _proxyDetectionService;
  final Future<String?> Function() _pickDirectory;
  final Future<bool> Function(String path) _validateDirectory;
  int _jpegToggleRevision = 0;

  PayloadConfig get payloadConfig => GetIt.I();
  ConfigService get configService => GetIt.I();

  double navigationDirectoryScrollOffset = 0;
  AppDestination? navigationDirectoryAnchor;

  SettingsPageViewmodel({
    ProxyDetectionService? proxyDetectionService,
    Future<String?> Function()? pickDirectory,
    Future<bool> Function(String path)? validateDirectory,
  })  : _proxyDetectionService =
            proxyDetectionService ?? ProxyDetectionService(),
        _pickDirectory =
            pickDirectory ?? (() => FilePicker.platform.getDirectoryPath()),
        _validateDirectory = validateDirectory ?? _isWritableDirectory;

  /// JPEG storage is intentionally a desktop-only option. `defaultTargetPlatform`
  /// is used instead of `Platform.is*` so the UI seam remains testable.
  bool supportsDesktopJpegStorage({TargetPlatform? platform}) {
    if (kIsWeb) return false;
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      case TargetPlatform.linux:
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  Settings get settings {
    return payloadConfig.settings;
  }

  /// Re-reads settings-backed state (e.g. after returning from a sub-page).
  void refresh() {
    notifyListeners();
  }

  void setApiKey(String value) {
    payloadConfig.settings.updatePrimaryApiKey(value);
    notifyListeners();
  }

  void setRememberSequentialProgress(bool? value) {
    if (value == null) return;
    payloadConfig.settings.rememberSequentialProgress = value;
    configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  void setConfirmPromptModeSwitch(bool value) {
    payloadConfig.settings.confirmPromptModeSwitch = value;
    configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  void setPromptAutocompleteEnabled(bool? value) {
    if (value == null) return;
    payloadConfig.settings.promptAutocompleteEnabled = value;
    configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  void setNavigationDestinationEnabled(
    AppDestination destination,
    bool enabled,
  ) {
    if (!settings.navigation.setEnabled(destination, enabled)) return;
    configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  void reorderNavigationDestination(int oldIndex, int newIndex) {
    if (!settings.navigation.reorder(oldIndex, newIndex)) return;
    configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  void openNavigationDestination(AppDestination destination) {
    navigationDirectoryAnchor = destination;
    GetIt.I<NavigationRequest>().goToFromSettingsDirectory(destination);
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
    await configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  /// Enables JPEG publication only after the output folder has passed a
  /// write probe. JPEG is always published to the shared output folder; a
  /// cancelled or invalid picker result leaves PNG-only mode untouched.
  Future<void> setJpegStorageEnabled(bool? value) async {
    if (value == null) return;
    final revision = ++_jpegToggleRevision;
    if (!value) {
      payloadConfig.settings.jpegStorageEnabled = false;
      await configService.saveConfig(payloadConfig.toJson());
      notifyListeners();
      return;
    }

    var directory = payloadConfig.settings.outputFolderPath.trim();
    var valid = directory.isNotEmpty && await _validateDirectory(directory);
    if (revision != _jpegToggleRevision) return;
    if (!valid) {
      directory = (await _pickDirectory())?.trim() ?? '';
      if (revision != _jpegToggleRevision || directory.isEmpty) return;
      valid = await _validateDirectory(directory);
      if (!valid || revision != _jpegToggleRevision) return;
    }

    payloadConfig.settings
      ..outputFolderPath = directory
      ..jpegStorageEnabled = true;
    await configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  Future<void> setRetainOriginalPng(bool? value) async {
    if (value == null) return;
    if (!value) {
      payloadConfig.settings.retainOriginalPng = false;
      await configService.saveConfig(payloadConfig.toJson());
      notifyListeners();
      return;
    }
    var directory = payloadConfig.settings.outputFolderPath.trim();
    var valid = directory.isNotEmpty && await _validateDirectory(directory);
    if (!valid) {
      directory = (await _pickDirectory())?.trim() ?? '';
      if (directory.isEmpty) return;
      valid = await _validateDirectory(directory);
      if (!valid) return;
    }
    payloadConfig.settings
      ..outputFolderPath = directory
      ..retainOriginalPng = true;
    await configService.saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  static Future<bool> _isWritableDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return false;
    final probe = File(
      '$path${Platform.pathSeparator}.casrand-write-test-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await probe.writeAsBytes(const <int>[0], flush: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {
        // A failed cleanup should not turn a successful write probe into a
        // false negative; the next validation can remove the stale probe.
      }
    }
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

  Future<String?> detectProxy() => _proxyDetectionService.detect();

  void loadJsonConfig(BuildContext context) async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return;
    try {
      var fileContent = utf8.decode(result.files.single.bytes!);
      Map<String, dynamic> jsonData = json.decode(fileContent);
      payloadConfig.loadJson(jsonData);
      notifyListeners();
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

  void notify() {
    notifyListeners();
  }

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
