import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nai_casrand/data/services/config_service.dart';

class _FailingBox implements Box<dynamic> {
  _FailingBox(this.delegate);

  final Box<dynamic> delegate;
  bool failNextPutAll = false;
  bool failNextDelete = false;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      delegate.get(key, defaultValue: defaultValue);

  @override
  Iterable<dynamic> get keys => delegate.keys;

  @override
  Future<void> put(dynamic key, dynamic value) => delegate.put(key, value);

  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) {
    if (failNextPutAll) {
      failNextPutAll = false;
      return Future.error(StateError('simulated putAll failure'));
    }
    return delegate.putAll(entries);
  }

  @override
  Future<void> delete(dynamic key) {
    if (failNextDelete) {
      failNextDelete = false;
      return Future.error(StateError('simulated delete failure'));
    }
    return delegate.delete(key);
  }

  @override
  Future<void> compact() => delegate.compact();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Box call: $invocation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;
  late Box<dynamic> saveBox;
  late ConfigService configService;

  setUp(() async {
    temporaryDirectory =
        await Directory.systemTemp.createTemp('casrand-config-service-test-');
    Hive.init(temporaryDirectory.path);
    saveBox = await Hive.openBox<dynamic>('savedBox');
    configService = ConfigService()
      ..saveBox = saveBox
      ..currentUuid = 'existing-config'
      ..configIndex = {
        'existing-config': SavedConfigInfo(
          title: 'Existing config',
          lastModified: DateTime(2026),
        ),
      };
    await saveBox.put(
      'savedConfig-existing-config',
      json.encode({'marker': 'must stay unchanged'}),
    );
    await saveBox.put('savedUuid', 'existing-config');
    await configService.saveConfigIndex();
  });

  tearDown(() async {
    await Hive.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test('saving a new current config preserves every existing saved config',
      () async {
    final newUuid = await configService.saveNewConfig(
      {'marker': 'initial settings'},
      title: 'Initial settings',
      makeCurrent: true,
    );

    expect(newUuid, isNot('existing-config'));
    expect(
      json.decode(saveBox.get('savedConfig-existing-config') as String),
      {'marker': 'must stay unchanged'},
    );
    expect(
      json.decode(saveBox.get('savedConfig-$newUuid') as String),
      {'marker': 'initial settings'},
    );
    expect(configService.configIndex.keys,
        containsAll(['existing-config', newUuid]));
    expect(configService.configIndex[newUuid]!.title, 'Initial settings');
    expect(configService.currentUuid, newUuid);
    expect(saveBox.get('savedUuid'), newUuid);

    final persistedIndex = json.decode(saveBox.get('configIndex') as String)
        as Map<String, dynamic>;
    expect(persistedIndex.keys, containsAll(['existing-config', newUuid]));
  });

  test('saveConfig completes only after settings are written to Hive',
      () async {
    await configService.saveConfig({
      'settings': {'metadata_erase_enabled': false},
    });

    expect(saveBox.get('savedUuid'), 'existing-config');
    expect(
      json.decode(
        saveBox.get('savedConfig-existing-config') as String,
      ),
      {
        'settings': {'metadata_erase_enabled': false},
      },
    );
    expect(saveBox.get('configIndex'), isA<String>());
  });

  test('a save stays bound to the config selected when it was accepted',
      () async {
    final pendingSave = configService.saveConfig({'marker': 'edited A'});

    configService.currentUuid = 'config-b';
    await pendingSave;

    expect(
      json.decode(saveBox.get('savedConfig-existing-config') as String),
      {'marker': 'edited A'},
    );
    expect(saveBox.get('savedConfig-config-b'), isNull);
  });

  test('flush waits for every accepted save before returning', () async {
    configService.saveConfig({'marker': 'accepted before exit'});

    await configService.flush();

    expect(
      json.decode(saveBox.get('savedConfig-existing-config') as String),
      {'marker': 'accepted before exit'},
    );
  });

  test('accepted saves for one config finish in user action order', () async {
    configService.saveConfig({'marker': 'older'});
    configService.saveConfig({'marker': 'latest'});

    await configService.flush();

    expect(
      json.decode(saveBox.get('savedConfig-existing-config') as String),
      {'marker': 'latest'},
    );
  });

  test('a failed config transaction preserves the prior readable version',
      () async {
    final previousEntity = saveBox.get('savedConfig-existing-config');
    final previousIndex = saveBox.get('configIndex');
    final previousModified =
        configService.configIndex['existing-config']!.lastModified;
    final failingBox = _FailingBox(saveBox)..failNextPutAll = true;
    configService.saveBox = failingBox;

    await expectLater(
      configService.saveConfig({'marker': 'must not become visible'}),
      throwsA(isA<StateError>()),
    );
    await expectLater(configService.flush(), throwsA(isA<StateError>()));

    expect(saveBox.get('savedConfig-existing-config'), previousEntity);
    expect(saveBox.get('configIndex'), previousIndex);
    expect(
      configService.configIndex['existing-config']!.lastModified,
      previousModified,
    );
  });

  test('deleting a saved config persists both entity and index', () async {
    final deletedUuid = await configService.saveNewConfig(
      {'marker': 'delete me'},
      title: 'Delete me',
    );

    await configService.deleteConfigByUuid(deletedUuid);
    await configService.flush();

    expect(saveBox.get('savedConfig-$deletedUuid'), isNull);
    final persistedIndex = json.decode(saveBox.get('configIndex') as String)
        as Map<String, dynamic>;
    expect(persistedIndex, isNot(contains(deletedUuid)));
  });

  test('a failed config deletion restores both entity and index', () async {
    final deletedUuid = await configService.saveNewConfig(
      {'marker': 'keep me'},
      title: 'Keep me',
    );
    final previousEntity = saveBox.get('savedConfig-$deletedUuid');
    final previousIndex = saveBox.get('configIndex');
    configService.saveBox = _FailingBox(saveBox)..failNextDelete = true;

    await expectLater(
      configService.deleteConfigByUuid(deletedUuid),
      throwsA(isA<StateError>()),
    );
    await expectLater(configService.flush(), throwsA(isA<StateError>()));

    expect(saveBox.get('savedConfig-$deletedUuid'), previousEntity);
    expect(saveBox.get('configIndex'), previousIndex);
    expect(configService.configIndex, contains(deletedUuid));
  });

  test('selecting a saved config persists the next-launch selection', () async {
    final validConfig = json.decode(
      await rootBundle.loadString('assets/json/example.json'),
    ) as Map<String, dynamic>;
    validConfig['marker'] = 'selected';
    final selectedUuid = await configService.saveNewConfig(
      validConfig,
      title: 'Selected config',
    );

    final selected = await configService.selectConfig(selectedUuid);
    await configService.flush();

    expect(selected['marker'], 'selected');
    expect(configService.currentUuid, selectedUuid);
    expect(saveBox.get('savedUuid'), selectedUuid);
  });

  test('startup bypasses a damaged current entry and keeps a healthy save',
      () async {
    final healthyConfig = json.decode(
      await rootBundle.loadString('assets/json/example.json'),
    ) as Map<String, dynamic>;
    await saveBox.putAll({
      'savedUuid': 'damaged-config',
      'savedConfig-damaged-config': json.encode({
        'prompt_config': <String, dynamic>{},
        'settings': <dynamic>[],
      }),
      'savedConfig-healthy-config': json.encode(healthyConfig),
      'configIndex': json.encode({
        'damaged-config': SavedConfigInfo(
          title: 'Damaged',
          lastModified: DateTime(2026, 1, 2),
        ).toJson(),
        'healthy-config': SavedConfigInfo(
          title: 'Healthy',
          lastModified: DateTime(2026, 1, 1),
        ).toJson(),
      }),
    });
    final restartingService = ConfigService();

    final restored = await restartingService.loadSavedConfigFromBox(saveBox);

    expect(restored['settings'], isA<Map<String, dynamic>>());
    expect(restartingService.currentUuid, 'healthy-config');
    expect(saveBox.get('savedUuid'), 'healthy-config');
    expect(restartingService.damagedConfigUuids, {'damaged-config'});
    expect(restartingService.configIndex.keys,
        containsAll(['damaged-config', 'healthy-config']));
  });

  test('startup recovers a healthy indexed save when current id is malformed',
      () async {
    final healthyConfig = json.decode(
      await rootBundle.loadString('assets/json/example.json'),
    ) as Map<String, dynamic>;
    healthyConfig['marker'] = 'healthy indexed config';
    await saveBox.putAll({
      'savedUuid': 17,
      'savedConfig-healthy-config': json.encode(healthyConfig),
      'configIndex': json.encode({
        'healthy-config': SavedConfigInfo(
          title: 'Healthy',
          lastModified: DateTime(2026, 1, 1),
        ).toJson(),
      }),
    });
    final restartingService = ConfigService();

    final restored = await restartingService.loadSavedConfigFromBox(saveBox);

    expect(restored['marker'], 'healthy indexed config');
    expect(restartingService.currentUuid, 'healthy-config');
    expect(saveBox.get('savedUuid'), 'healthy-config');
  });

  test('invalid import is rejected before any persistent mutation', () async {
    final beforeKeys = saveBox.keys.toSet();
    final beforeIndex = saveBox.get('configIndex');

    expect(
      () => configService.saveImportedConfig(
        {
          'prompt_config': <String, dynamic>{},
          'settings': <dynamic>[],
        },
        title: 'Invalid import',
      ),
      throwsA(isA<ConfigValidationException>()),
    );

    expect(saveBox.keys.toSet(), beforeKeys);
    expect(saveBox.get('configIndex'), beforeIndex);
    expect(configService.configIndex.keys, {'existing-config'});
  });

  test('startup creates a safe config when every indexed entry is damaged',
      () async {
    await saveBox.putAll({
      'savedUuid': 'damaged-config',
      'savedConfig-damaged-config': '{bad json',
      'configIndex': json.encode({
        'damaged-config': SavedConfigInfo(
          title: 'Keep damaged entry',
          lastModified: DateTime(2026),
        ).toJson(),
      }),
    });
    final restartingService = ConfigService();

    final restored = await restartingService.loadSavedConfigFromBox(saveBox);

    expect(restored['settings'], isA<Map<String, dynamic>>());
    expect(restartingService.currentUuid, isNot('damaged-config'));
    expect(restartingService.configIndex, contains('damaged-config'));
    expect(restartingService.damagedConfigUuids, {'damaged-config'});
    expect(
      saveBox.get('savedConfig-damaged-config'),
      '{bad json',
    );
  });
}
