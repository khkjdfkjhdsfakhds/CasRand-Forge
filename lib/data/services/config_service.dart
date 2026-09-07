import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class SavedConfigInfo {
  String title;
  DateTime lastModified;

  SavedConfigInfo({
    required this.title,
    required this.lastModified,
  });

  factory SavedConfigInfo.fromJson(Map<String, dynamic> json) {
    final jsonDate = DateTime.tryParse(json['lastModified'] ?? '');
    return SavedConfigInfo(
      title: json['title'] ?? 'Unnamed',
      lastModified: jsonDate ?? DateTime.fromMicrosecondsSinceEpoch(0),
    );
  }

  factory SavedConfigInfo.fromEmpty() {
    return SavedConfigInfo(
      title: 'Unnamed',
      lastModified: DateTime.fromMicrosecondsSinceEpoch(0),
    );
  }

  Map<String, String> toJson() {
    return {
      'title': title,
      'lastModified': lastModified.toIso8601String(),
    };
  }
}

class ConfigService {
  late PackageInfo packageInfo;
  late Box saveBox;

  late String currentUuid;
  late Map<String, SavedConfigInfo> configIndex;

  Future<String> loadDefaultConfig() async {
    return await rootBundle.loadString('assets/json/example.json');
  }

  Future<Map<String, dynamic>> loadSavedConfig() async {
    if (!kIsWeb) {
      final dir = Platform.isMacOS
          ? await getApplicationSupportDirectory()
          : await getApplicationDocumentsDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      Hive.init(dir.path);
    }
    saveBox = await Hive.openBox('savedBox');
    configIndex = loadConfigIndex();
    String? savedUuid = saveBox.get('savedUuid');
    String? jsonData;

    // Load saved config, or use example config
    if (savedUuid == null) {
      jsonData = saveBox.get('savedConfig');
    } else {
      jsonData = saveBox.get('savedConfig-$savedUuid');
    }
    jsonData ??= await loadDefaultConfig();

    // Set current UUID
    if (savedUuid == null) {
      currentUuid = const Uuid().v4();
      saveConfig(json.decode(jsonData));
    } else {
      currentUuid = savedUuid;
    }
    saveBox.delete('savedConfig');
    saveBox.compact();

    if (kDebugMode) {
      print('Loaded keys:\n${saveBox.keys.toList().join('\n')}');
      print('Config indexes: ${configIndex.toString()}');
      print('Saved UUID: $savedUuid');
    }

    return json.decode(jsonData);
  }

  Future<void> saveConfig(Map<String, dynamic> jsonData) async {
    // Let the initiating UI event finish before encoding and writing the config.
    await Future<void>.delayed(Duration.zero);
    saveBox.put('savedUuid', currentUuid);
    saveConfigByUuid(currentUuid, jsonData);
  }

  /// Returns
  ///
  /// {'uuid1': {'title': 'title1', 'lastModified': 'timestamp1'}, 'uuid2': ..., ...}
  Map<String, SavedConfigInfo> loadConfigIndex() {
    final jsonString = saveBox.get('configIndex');
    if (jsonString == null) {
      return {};
    }
    try {
      final jsonData = json.decode(jsonString) as Map<String, dynamic>;
      return jsonData.cast<String, Map<String, dynamic>>().map(
            (uuid, configInfoJson) => MapEntry(
              uuid,
              SavedConfigInfo.fromJson(configInfoJson),
            ),
          );
    } catch (e) {
      if (kDebugMode) {
        print('Error loading config indexes: $e');
      }
      return {};
    }
  }

  void saveConfigIndex() {
    final encodedIndex = configIndex.map(
      (uuid, savedConfigInfo) => MapEntry(
        uuid,
        savedConfigInfo.toJson(),
      ),
    );
    saveBox.put('configIndex', json.encode(encodedIndex));
  }

  Map<String, dynamic>? loadConfigByUuid(String uuid) {
    final configJsonString = saveBox.get('savedConfig-$uuid');
    if (configJsonString == null) {
      return null;
    }
    return json.decode(configJsonString);
  }

  void renameConfigByUuid(String uuid, String title) {
    if (!configIndex.containsKey(uuid)) return;
    configIndex[uuid]!.title = title;
    saveConfigIndex();
  }

  void saveConfigByUuid(String uuid, Map<String, dynamic> jsonData) {
    if (kDebugMode) {
      print('Saving config: $uuid');
    }
    saveBox.put('savedConfig-$uuid', json.encode(jsonData));
    if (!configIndex.containsKey(uuid)) {
      configIndex[uuid] = SavedConfigInfo.fromEmpty();
    }
    configIndex[uuid]!.lastModified = DateTime.now();
    saveConfigIndex();
  }

  Future<String> saveNewConfig(
    Map<String, dynamic> jsonData, {
    required String title,
    bool makeCurrent = false,
  }) async {
    final uuid = const Uuid().v4();
    await saveBox.put('savedConfig-$uuid', json.encode(jsonData));
    configIndex[uuid] = SavedConfigInfo(
      title: title,
      lastModified: DateTime.now(),
    );
    final encodedIndex = configIndex.map(
      (configUuid, savedConfigInfo) => MapEntry(
        configUuid,
        savedConfigInfo.toJson(),
      ),
    );
    await saveBox.put('configIndex', json.encode(encodedIndex));
    if (makeCurrent) {
      currentUuid = uuid;
      await saveBox.put('savedUuid', uuid);
    }
    return uuid;
  }

  void deleteConfigByUuid(String uuid) {
    if (uuid == currentUuid) return;
    saveBox.delete('savedConfig-$uuid');
    configIndex.remove(uuid);
  }
}
