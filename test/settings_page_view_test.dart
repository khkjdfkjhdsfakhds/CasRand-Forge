import 'dart:convert';
import 'dart:io';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:image/image.dart' as img;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/data/services/proxy_detection_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/settings_page_viewmodel.dart';
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
  Future<void> saveConfig(Map<String, dynamic> jsonData) async {
    savedConfigs[currentUuid] =
        json.decode(json.encode(jsonData)) as Map<String, dynamic>;
  }

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
    GetIt.instance.registerSingleton(NavigationRequest());
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

  Widget localizedSettingsPage({SettingsPageViewmodel? viewmodel}) {
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
            home: SettingsPageView(viewmodel: viewmodel),
          ),
        ),
      ),
    );
  }

  testWidgets('setup entry is combined and behavior toggles follow output', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    try {
      await tester.pumpWidget(localizedSettingsPage());
      await tester.pumpAndSettle();

      final setup = find.byKey(const Key('api-proxy-settings-tile'));
      final metadata = find.byKey(const Key('metadata-erase-enabled'));
      final output = find.byKey(const Key('output-folder'));
      final prefix = find.byKey(const Key('output-file-name-prefix'));
      final remember = find.byKey(const Key('remember-sequential-progress'));
      final confirmation = find.byKey(const Key('confirm-prompt-mode-switch'));

      expect(setup, findsOneWidget);
      expect(find.text('API & Proxy Settings'), findsOneWidget);
      expect(find.byKey(const Key('proxy-settings-tile')), findsNothing);
      expect(find.byKey(const Key('multi-token-manager-tile')), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(tester.getTopLeft(setup).dy,
          lessThan(tester.getTopLeft(metadata).dy));
      if (Platform.isMacOS || Platform.isWindows) {
        expect(output, findsOneWidget);
        expect(tester.getTopLeft(metadata).dy,
            lessThan(tester.getTopLeft(output).dy));
        expect(tester.getTopLeft(output).dy,
            lessThan(tester.getTopLeft(prefix).dy));
      } else {
        expect(output, findsNothing);
        expect(tester.getTopLeft(metadata).dy,
            lessThan(tester.getTopLeft(prefix).dy));
      }
      expect(tester.getTopLeft(prefix).dy,
          lessThan(tester.getTopLeft(remember).dy));
      expect(
        tester.getTopLeft(remember).dy,
        lessThan(tester.getTopLeft(confirmation).dy),
      );

      expect(GetIt.I<PayloadConfig>().settings.rememberSequentialProgress,
          isFalse);
      await tester.tap(remember);
      await tester.pump();
      expect(
        GetIt.I<PayloadConfig>().settings.rememberSequentialProgress,
        isTrue,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('combined setup contains required API, optional APIs and proxy', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(localizedSettingsPage());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('api-proxy-settings-tile')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-token-input')), findsOneWidget);
      expect(find.text('NovelAI API Token (required)'), findsOneWidget);
      expect(find.text('Multiple APIs (optional)'), findsOneWidget);
      expect(find.textContaining('1 tokens configured, 1 enabled'),
          findsOneWidget);
      expect(find.text('Proxy Settings'), findsOneWidget);
      expect(find.byKey(const Key('proxy-settings-input')), findsOneWidget);
      expect(find.byKey(const Key('proxy-detect-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('api-tokens-optional-tile')));
      await tester.pumpAndSettle();
      expect(find.text('Multi-token concurrency'), findsOneWidget);
      expect(
        find.byKey(const Key('token-manager-parallel-switch')),
        findsOneWidget,
      );
      expect(find.text('Main'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('desktop proxy detection fills the edit field before confirm', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final proxyDetector = ProxyDetectionService(
        ports: const [7890],
        probe: (host, port, timeout) async => true,
      );
      final viewmodel = SettingsPageViewmodel(
        proxyDetectionService: proxyDetector,
      );
      await tester.pumpWidget(localizedSettingsPage(viewmodel: viewmodel));
      await tester.pumpAndSettle();

      final setupTile = find.byKey(const Key('api-proxy-settings-tile'));
      expect(setupTile, findsOneWidget);
      await tester.ensureVisible(setupTile);
      await tester.tap(setupTile);
      await tester.pumpAndSettle();

      expect(find.text('API & Proxy Settings'), findsNWidgets(2));
      expect(find.byKey(const Key('proxy-detect-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('proxy-detect-button')));
      await tester.pumpAndSettle();

      final input = tester.widget<TextField>(
        find.byKey(const Key('proxy-settings-input')),
      );
      expect(input.controller?.text, '127.0.0.1:7890');
      expect(
        find.text('Local proxy detected: 127.0.0.1:7890'),
        findsOneWidget,
      );
      expect(GetIt.I<PayloadConfig>().settings.proxy, isEmpty);

      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(GetIt.I<PayloadConfig>().settings.proxy, '127.0.0.1:7890');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('welcome navigation request opens combined setup directly', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final navigation = GetIt.I<NavigationRequest>();
      navigation.goToApiProxySettings();
      expect(navigation.requestedDestination.value, AppDestination.settings);
      expect(
        testTranslations['welcome_message_markdown'],
        contains('#jump_to_api_proxy_settings'),
      );
      expect(
        testTranslations['welcome_message_markdown'],
        isNot(contains('#jump_to_settings')),
      );

      await tester.pumpWidget(localizedSettingsPage());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('api-token-input')), findsOneWidget);
      expect(find.byKey(const Key('proxy-settings-input')), findsOneWidget);
      expect(find.byKey(const Key('proxy-detect-button')), findsOneWidget);
      expect(navigation.takeOpenApiProxySettingsRequest(), isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile proxy settings follow VPN or TUN when left blank', (
    tester,
  ) async {
    await tester.pumpWidget(localizedSettingsPage());
    await tester.pumpAndSettle();

    final setupTile = find.byKey(const Key('api-proxy-settings-tile'));
    await tester.ensureVisible(setupTile);
    await tester.tap(setupTile);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('proxy-detect-button')), findsNothing);
    expect(
      find.text(
        'Leave this blank when your mobile proxy app uses VPN / TUN mode. '
        'Enter a value only when the proxy app explicitly provides a local '
        'HTTP proxy port.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('settings contains one seven-item navigation directory', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(localizedSettingsPage());
    await tester.pumpAndSettle();

    expect(find.text('Feature navigation settings'), findsOneWidget);
    expect(
      find.text(
        'Click a function to open it temporarily; use its switch to pin it '
        'to the Home screen, and drag to reorder.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('navigation-directory-list')), findsOneWidget);
    for (final destination in AppDestination.values) {
      expect(
        find.byKey(
          ValueKey('navigation-directory-item-${destination.name}'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ValueKey('navigation-directory-reorder-${destination.name}'),
        ),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey('navigation-directory-required-generation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('navigation-directory-required-config')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('navigation-directory-required-settings')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('navigation-directory-list')),
        matching: find.byType(Switch),
      ),
      findsNWidgets(4),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('navigation-directory-list')),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
    expect(find.byType(Divider), findsNWidgets(2));
    expect(find.text('More'), findsNothing);
  });

  testWidgets('directory name opens without enabling and switch only enables', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final navigationRequest = GetIt.I<NavigationRequest>();
    final configuration = GetIt.I<PayloadConfig>().settings.navigation;

    await tester.pumpWidget(localizedSettingsPage());
    await tester.pumpAndSettle();

    final open = find.byKey(
      const ValueKey('navigation-directory-open-imageToImage'),
    );
    final toggle = find.byKey(
      const ValueKey('navigation-directory-toggle-imageToImage'),
    );
    await tester.tap(open);
    await tester.pump();

    expect(
      navigationRequest.requestedDestination.value,
      AppDestination.imageToImage,
    );
    expect(navigationRequest.openFromSettingsDirectory, isTrue);
    expect(configuration.contains(AppDestination.imageToImage), isFalse);

    navigationRequest.consume();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(configuration.contains(AppDestination.imageToImage), isTrue);
    expect(navigationRequest.requestedDestination.value, isNull);
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
  });

  testWidgets('directory restores its scroll context around the last function',
      (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewmodel = SettingsPageViewmodel();

    await tester.pumpWidget(localizedSettingsPage(viewmodel: viewmodel));
    await tester.pumpAndSettle();

    final director = find.byKey(
      const ValueKey('navigation-directory-open-directorTools'),
    );
    await tester.ensureVisible(director);
    await tester.pumpAndSettle();
    await tester.tap(director);
    await tester.pump();
    final rememberedOffset = viewmodel.navigationDirectoryScrollOffset;
    expect(rememberedOffset, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(localizedSettingsPage(viewmodel: viewmodel));
    await tester.pumpAndSettle();

    final directorRect = tester.getRect(director);
    expect(directorRect.bottom, greaterThan(0));
    expect(directorRect.top, lessThan(600));
    final scrollView = tester.widget<SingleChildScrollView>(
      find.byKey(const Key('settings-scroll-view')),
    );
    expect(scrollView.controller!.offset, closeTo(rememberedOffset, 1));

    final restoredOffset = scrollView.controller!.position.maxScrollExtent;
    scrollView.controller!.jumpTo(restoredOffset);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(localizedSettingsPage(viewmodel: viewmodel));
    await tester.pumpAndSettle();

    final ordinaryEntryScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const Key('settings-scroll-view')),
    );
    expect(
      ordinaryEntryScroll.controller!.offset,
      closeTo(restoredOffset, 1),
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
