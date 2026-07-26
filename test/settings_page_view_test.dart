import 'dart:convert';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:image/image.dart' as img;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/widgets/settings_page_view.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

class _FakeConfigService extends ConfigService {
  final Map<String, dynamic> defaultConfig;
  final Map<String, Map<String, dynamic>> savedConfigs = {};
  int _newConfigCounter = 0;

  _FakeConfigService(this.defaultConfig) {
    currentUuid = 'existing-config';
    configIndex = {
      currentUuid: SavedConfigInfo(
        title: 'Existing config',
        lastModified: DateTime(2026),
      ),
    };
    savedConfigs[currentUuid] = {'marker': 'must stay unchanged'};
  }

  @override
  Future<String> loadDefaultConfig() async => json.encode(defaultConfig);

  @override
  Future<String> saveNewConfig(
    Map<String, dynamic> jsonData, {
    required String title,
    bool makeCurrent = false,
  }) async {
    final uuid = 'new-config-${++_newConfigCounter}';
    savedConfigs[uuid] =
        json.decode(json.encode(jsonData)) as Map<String, dynamic>;
    configIndex[uuid] = SavedConfigInfo(
      title: title,
      lastModified: DateTime(2026, 7, 20, _newConfigCounter),
    );
    if (makeCurrent) currentUuid = uuid;
    return uuid;
  }
}

void main() {
  Map<String, dynamic> defaultConfigJson() => {
        'prompt_config': PromptConfig(
          shuffled: false,
          comment: 'Initial prompt',
          strs: ['initial positive'],
          prompts: [],
        ).toJson(),
        'character_config': <dynamic>[],
        'saved_config': <dynamic>[],
        'param_config': ParamConfig().toJson(),
        'settings': Settings.fromJson({
          'api_key': 'initial api key',
          'theme_mode': 'system',
        }).toJson(),
      };

  late _FakeConfigService configService;
  late Map<String, dynamic> testTranslations;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    final source = await rootBundle.loadString('assets/l10n/en.json');
    testTranslations = json.decode(source) as Map<String, dynamic>;
  });

  setUp(() async {
    await GetIt.instance.reset();
    configService = _FakeConfigService(defaultConfigJson());
    GetIt.instance.registerSingleton<ConfigService>(configService);
    GetIt.instance.registerSingleton(
      PayloadConfig(
        rootPromptConfig: PromptConfig(strs: [], prompts: []),
        negativePromptConfig: PromptConfig(
          shuffled: false,
          strs: ['test negative prompt'],
          prompts: [],
        ),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(),
        settings: Settings.fromJson({}),
        overridePrompt: '',
        useOverridePrompt: false,
        useCharacterPromptWithOverride: false,
      ),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  Widget localizedSettingsPage() {
    return EasyLocalization(
      key: UniqueKey(),
      supportedLocales: const [Locale('en')],
      path: 'test',
      assetLoader: _TestAssetLoader(testTranslations),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
        builder: (context) => AdaptiveTheme(
          light: ThemeData.light(),
          dark: ThemeData.dark(),
          initial: AdaptiveThemeMode.dark,
          builder: (theme, darkTheme) => MaterialApp(
            theme: theme,
            darkTheme: darkTheme,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: SettingsPageView(),
          ),
        ),
      ),
    );
  }

  testWidgets('sequential progress memory is shown and defaults disabled', (
    tester,
  ) async {
    await tester.pumpWidget(localizedSettingsPage());
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(
      CheckboxListTile,
      'Remember sequential progress',
    );
    expect(tile, findsOneWidget);
    expect(
        GetIt.I<PayloadConfig>().settings.rememberSequentialProgress, isFalse);

    await tester.tap(tile);
    await tester.pump();

    expect(
      GetIt.I<PayloadConfig>().settings.rememberSequentialProgress,
      isTrue,
    );
  });

  testWidgets('restore entry is below saved configs and requires a choice', (
    tester,
  ) async {
    await tester.pumpWidget(localizedSettingsPage());
    await tester.pumpAndSettle();

    final savedConfigTile = find.text('Saved Config');
    final restoreTile = find.byKey(const Key('restore-initial-settings-tile'));
    final themeTile = find.text('Theme Mode');
    expect(restoreTile, findsOneWidget);
    expect(
      tester.getTopLeft(savedConfigTile).dy,
      lessThan(tester.getTopLeft(restoreTile).dy),
    );
    expect(
      tester.getTopLeft(restoreTile).dy,
      lessThan(tester.getTopLeft(themeTile).dy),
    );

    await tester.ensureVisible(restoreTile);
    await tester.tap(restoreTile);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Existing entries under Saved Configs'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('restore-initial-settings-cancel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('restore-initial-settings-backup')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('restore-initial-settings-direct')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('restore-initial-settings-cancel')),
    );
    await tester.pumpAndSettle();
    expect(configService.savedConfigs, hasLength(1));
  });

  testWidgets('backup and restore preserves saves and resets all active state',
      (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig
      ..rootPromptConfig.comment = 'Current prompt'
      ..settings.apiKey = 'current api key'
      ..overridePrompt = 'current override'
      ..useOverridePrompt = true;
    payloadConfig.i2iConfig.setImage(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
    payloadConfig.vibeConfigList.add(VibeConfig(
      imageB64: 'vibe',
      fileName: 'vibe.png',
      infoExtracted: 1,
      referenceStrength: 0.3,
    ));
    payloadConfig.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'vibe.naiv4vibe',
      vibeB64: 'vibe-v4',
      referenceStrength: 0.2,
    ));
    payloadConfig.preciseReferenceConfigList.add(PreciseReferenceConfig(
      imageB64: 'precise-reference',
      fileName: 'precise.png',
    ));

    await tester.pumpWidget(localizedSettingsPage());
    await tester.pumpAndSettle();
    final restoreTile = find.byKey(const Key('restore-initial-settings-tile'));
    await tester.ensureVisible(restoreTile);
    await tester.tap(restoreTile);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('restore-initial-settings-backup')),
    );
    await tester.pumpAndSettle();

    expect(configService.savedConfigs['existing-config'], {
      'marker': 'must stay unchanged',
    });
    expect(configService.savedConfigs, hasLength(3));
    expect(
      configService.configIndex.values.map((info) => info.title),
      containsAll(['Backup before restore', 'Initial settings']),
    );
    expect(
      configService.configIndex[configService.currentUuid]!.title,
      'Initial settings',
    );
    expect(payloadConfig.rootPromptConfig.comment, 'Initial prompt');
    expect(payloadConfig.settings.apiKey, 'initial api key');
    expect(payloadConfig.settings.themeMode, 'system');
    expect(payloadConfig.overridePrompt, isEmpty);
    expect(payloadConfig.useOverridePrompt, isFalse);
    expect(payloadConfig.i2iConfig.imageB64, isNull);
    expect(payloadConfig.vibeConfigList, isEmpty);
    expect(payloadConfig.vibeConfigListV4, isEmpty);
    expect(payloadConfig.preciseReferenceConfigList, isEmpty);

    final backupUuid = configService.configIndex.entries
        .singleWhere((entry) => entry.value.title == 'Backup before restore')
        .key;
    expect(
      configService.savedConfigs[backupUuid]!['prompt_config']['comment'],
      'Current prompt',
    );
    expect(
      configService.savedConfigs[backupUuid]!['settings']['api_key'],
      'current api key',
    );
  });

  testWidgets('direct restore does not create a backup or overwrite old saves',
      (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GetIt.I<PayloadConfig>().rootPromptConfig.comment = 'Discarded prompt';

    await tester.pumpWidget(localizedSettingsPage());
    await tester.pumpAndSettle();
    final restoreTile = find.byKey(const Key('restore-initial-settings-tile'));
    await tester.ensureVisible(restoreTile);
    await tester.tap(restoreTile);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('restore-initial-settings-direct')),
    );
    await tester.pumpAndSettle();

    expect(configService.savedConfigs['existing-config'], {
      'marker': 'must stay unchanged',
    });
    expect(configService.savedConfigs, hasLength(2));
    expect(
      configService.configIndex.values
          .where((info) => info.title == 'Backup before restore'),
      isEmpty,
    );
    expect(
      configService.configIndex[configService.currentUuid]!.title,
      'Initial settings',
    );
    expect(GetIt.I<PayloadConfig>().rootPromptConfig.comment, 'Initial prompt');
  });
}
