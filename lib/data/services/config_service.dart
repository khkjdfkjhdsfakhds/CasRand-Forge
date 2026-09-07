import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
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

class ConfigValidationException implements FormatException {
  @override
  final String message;

  const ConfigValidationException(this.message);

  @override
  int? get offset => null;

  @override
  dynamic get source => null;

  @override
  String toString() => 'Invalid configuration: $message';
}

class ConfigService {
  late PackageInfo packageInfo;
  late Box saveBox;

  late String currentUuid;
  late Map<String, SavedConfigInfo> configIndex;

  Future<void> _operationTail = Future<void>.value();
  Object? _unreportedPersistenceError;
  StackTrace? _unreportedPersistenceStackTrace;
  final Set<String> _damagedConfigUuids = <String>{};

  Set<String> get damagedConfigUuids => Set.unmodifiable(_damagedConfigUuids);

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
    final box = await Hive.openBox('savedBox');
    return loadSavedConfigFromBox(box);
  }

  /// Initializes the service from an already-open box. This is also the
  /// isolated-Hive seam used to verify restart and recovery behavior.
  Future<Map<String, dynamic>> loadSavedConfigFromBox(Box box) async {
    saveBox = box;
    configIndex = loadConfigIndex();
    _damagedConfigUuids.clear();
    final savedUuidValue = saveBox.get('savedUuid');
    final savedUuid = savedUuidValue is String ? savedUuidValue : null;

    if (savedUuid != null) {
      final current = _tryDecodeSavedConfig(savedUuid);
      if (current != null) {
        currentUuid = savedUuid;
        await _cleanupLegacyConfig();
        return current;
      }
      _damagedConfigUuids.add(savedUuid);
    }

    final fallbacks = configIndex.entries.toList()
      ..sort((a, b) => b.value.lastModified.compareTo(a.value.lastModified));
    for (final entry in fallbacks) {
      if (entry.key == savedUuid) continue;
      final recovered = _tryDecodeSavedConfig(entry.key);
      if (recovered == null) {
        _damagedConfigUuids.add(entry.key);
        continue;
      }
      currentUuid = entry.key;
      await saveBox.put('savedUuid', entry.key);
      await _cleanupLegacyConfig();
      return recovered;
    }

    final legacyJson = saveBox.get('savedConfig');
    if (legacyJson is String) {
      try {
        final legacy = json.decode(legacyJson) as Map<String, dynamic>;
        validateConfigJson(legacy);
        currentUuid = const Uuid().v4();
        final updated = _copyIndex()
          ..[currentUuid] = SavedConfigInfo.fromEmpty();
        await saveBox.putAll({
          'savedUuid': currentUuid,
          'savedConfig-$currentUuid': json.encode(legacy),
          'configIndex': _encodeConfigIndex(updated),
        });
        configIndex = updated;
        await _cleanupLegacyConfig();
        return legacy;
      } catch (_) {
        // The legacy entry remains untouched until a safe fallback is stored.
      }
    }

    final fallback =
        json.decode(await loadDefaultConfig()) as Map<String, dynamic>;
    validateConfigJson(fallback);
    currentUuid = const Uuid().v4();
    final updated = _copyIndex()
      ..[currentUuid] = SavedConfigInfo(
        title: 'Recovered configuration',
        lastModified: DateTime.now(),
      );
    await saveBox.putAll({
      'savedUuid': currentUuid,
      'savedConfig-$currentUuid': json.encode(fallback),
      'configIndex': _encodeConfigIndex(updated),
    });
    configIndex = updated;
    await _cleanupLegacyConfig();

    if (kDebugMode) {
      print('Loaded keys:\n${saveBox.keys.toList().join('\n')}');
      print('Config indexes: ${configIndex.toString()}');
      print('Saved UUID: $savedUuid');
    }

    return fallback;
  }

  Map<String, dynamic>? _tryDecodeSavedConfig(String uuid) {
    final stored = saveBox.get('savedConfig-$uuid');
    if (stored is! String) return null;
    try {
      final decoded = json.decode(stored) as Map<String, dynamic>;
      validateConfigJson(decoded);
      return decoded;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupLegacyConfig() async {
    await saveBox.delete('savedConfig');
    await saveBox.compact();
  }

  Future<void> saveConfig(Map<String, dynamic> jsonData) {
    final targetUuid = currentUuid;
    final snapshot = json.encode(jsonData);
    return _enqueue(() async {
      // Let the initiating UI event finish before writing the config.
      await Future<void>.delayed(Duration.zero);
      await _saveConfigByUuid(targetUuid, snapshot);
    });
  }

  /// Waits until every persistence operation accepted before this call has
  /// finished. The latest write failure is surfaced to exit and other callers.
  Future<void> flush() async {
    await _operationTail;
    final error = _unreportedPersistenceError;
    final stackTrace = _unreportedPersistenceStackTrace;
    _unreportedPersistenceError = null;
    _unreportedPersistenceStackTrace = null;
    if (error != null) Error.throwWithStackTrace(error, stackTrace!);
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final accepted = _operationTail.then((_) => operation());
    _operationTail = accepted.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _unreportedPersistenceError = error;
        _unreportedPersistenceStackTrace = stackTrace;
      },
    );
    return accepted;
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
      final validEntries = <String, SavedConfigInfo>{};
      for (final entry in jsonData.entries) {
        try {
          final value = entry.value;
          if (value is! Map<String, dynamic>) continue;
          validEntries[entry.key] = SavedConfigInfo.fromJson(value);
        } catch (_) {
          // A damaged index item must not hide unrelated healthy archives.
          // Keep the original box entry intact for later recovery.
        }
      }
      return validEntries;
    } catch (e) {
      if (kDebugMode) {
        print('Error loading config indexes: $e');
      }
      return {};
    }
  }

  Future<void> saveConfigIndex() async {
    final encodedIndex = _encodeConfigIndex(configIndex);
    return _enqueue(() => saveBox.put('configIndex', encodedIndex));
  }

  String _encodeConfigIndex(Map<String, SavedConfigInfo> index) {
    final encodedIndex = index.map(
      (uuid, savedConfigInfo) => MapEntry(
        uuid,
        savedConfigInfo.toJson(),
      ),
    );
    return json.encode(encodedIndex);
  }

  Map<String, dynamic>? loadConfigByUuid(String uuid) {
    final configJsonString = saveBox.get('savedConfig-$uuid');
    if (configJsonString == null) {
      return null;
    }
    return json.decode(configJsonString);
  }

  /// Makes [uuid] the durable current selection. When [currentConfig] is
  /// supplied, the outgoing configuration and the new selection are committed
  /// together from the caller's perspective.
  Future<Map<String, dynamic>> selectConfig(
    String uuid, {
    Map<String, dynamic>? currentConfig,
  }) {
    final outgoingUuid = currentUuid;
    final outgoingSnapshot =
        currentConfig == null ? null : json.encode(currentConfig);
    return _enqueue(() async {
      final selectedJson = saveBox.get('savedConfig-$uuid');
      if (selectedJson is! String) {
        throw StateError('Saved configuration $uuid does not exist.');
      }
      final selected = json.decode(selectedJson) as Map<String, dynamic>;
      validateConfigJson(selected);
      final updated = _copyIndex();
      final writes = <String, dynamic>{'savedUuid': uuid};
      if (outgoingSnapshot != null) {
        writes['savedConfig-$outgoingUuid'] = outgoingSnapshot;
        final outgoingInfo = updated[outgoingUuid];
        if (outgoingInfo != null) {
          updated[outgoingUuid] = SavedConfigInfo(
            title: outgoingInfo.title,
            lastModified: DateTime.now(),
          );
          writes['configIndex'] = _encodeConfigIndex(updated);
        }
      }
      await saveBox.putAll(writes);
      configIndex = updated;
      currentUuid = uuid;
      return selected;
    });
  }

  Future<void> renameConfigByUuid(String uuid, String title) {
    return _enqueue(() async {
      final current = configIndex[uuid];
      if (current == null) return;
      final updated = _copyIndex();
      updated[uuid] = SavedConfigInfo(
        title: title,
        lastModified: current.lastModified,
      );
      await saveBox.put('configIndex', _encodeConfigIndex(updated));
      configIndex = updated;
    });
  }

  Future<void> saveConfigByUuid(
    String uuid,
    Map<String, dynamic> jsonData,
  ) {
    final snapshot = json.encode(jsonData);
    return _enqueue(() => _saveConfigByUuid(uuid, snapshot));
  }

  Future<void> _saveConfigByUuid(String uuid, String encodedConfig) async {
    if (kDebugMode) {
      print('Saving config: $uuid');
    }
    final updated = _copyIndex();
    final previous = updated[uuid] ?? SavedConfigInfo.fromEmpty();
    updated[uuid] = SavedConfigInfo(
      title: previous.title,
      lastModified: DateTime.now(),
    );
    await saveBox.putAll({
      'savedConfig-$uuid': encodedConfig,
      'configIndex': _encodeConfigIndex(updated),
    });
    configIndex = updated;
  }

  Future<String> saveNewConfig(
    Map<String, dynamic> jsonData, {
    required String title,
    bool makeCurrent = false,
  }) {
    final uuid = const Uuid().v4();
    final snapshot = json.encode(jsonData);
    return _enqueue(() async {
      final updated = _copyIndex()
        ..[uuid] = SavedConfigInfo(
          title: title,
          lastModified: DateTime.now(),
        );
      await saveBox.putAll({
        'savedConfig-$uuid': snapshot,
        'configIndex': _encodeConfigIndex(updated),
        if (makeCurrent) 'savedUuid': uuid,
      });
      configIndex = updated;
      if (makeCurrent) currentUuid = uuid;
      return uuid;
    });
  }

  Future<String> saveImportedConfig(
    Map<String, dynamic> jsonData, {
    required String title,
    bool makeCurrent = false,
  }) {
    validateConfigJson(jsonData);
    return saveNewConfig(
      jsonData,
      title: title,
      makeCurrent: makeCurrent,
    );
  }

  void validateConfigJson(Map<String, dynamic> jsonData) {
    void requireMap(String key, {bool required = false}) {
      final value = jsonData[key];
      if (value == null && !required) return;
      if (value is! Map<String, dynamic>) {
        throw ConfigValidationException('$key must be an object.');
      }
    }

    void requireList(String key) {
      final value = jsonData[key];
      if (value != null && value is! List<dynamic>) {
        throw ConfigValidationException('$key must be a list.');
      }
    }

    requireMap('prompt_config', required: true);
    requireMap('negative_prompt_config');
    requireMap('param_config');
    requireMap('settings');
    requireMap('fixed_profile');
    requireMap('i2i_request_size');
    requireList('character_config');
    requireList('saved_config');
    try {
      PayloadConfig.fromJson(jsonData);
    } catch (error) {
      throw ConfigValidationException(error.toString());
    }
  }

  Future<void> deleteConfigByUuid(String uuid) {
    return _enqueue(() async {
      if (uuid == currentUuid || !configIndex.containsKey(uuid)) return;
      final previousEntity = saveBox.get('savedConfig-$uuid');
      final previousIndex = configIndex;
      final updated = _copyIndex()..remove(uuid);
      try {
        await saveBox.put('configIndex', _encodeConfigIndex(updated));
        await saveBox.delete('savedConfig-$uuid');
        configIndex = updated;
      } catch (_) {
        await saveBox.put('configIndex', _encodeConfigIndex(previousIndex));
        if (previousEntity != null) {
          await saveBox.put('savedConfig-$uuid', previousEntity);
        }
        rethrow;
      }
    });
  }

  Map<String, SavedConfigInfo> _copyIndex() {
    return configIndex.map(
      (uuid, info) => MapEntry(
        uuid,
        SavedConfigInfo(title: info.title, lastModified: info.lastModified),
      ),
    );
  }
}
