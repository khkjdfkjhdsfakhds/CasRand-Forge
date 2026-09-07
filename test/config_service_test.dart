import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nai_casrand/data/services/config_service.dart';

void main() {
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
    configService.saveConfigIndex();
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
}
