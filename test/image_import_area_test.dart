import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/config_page/widgets/config_page_view.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_page_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/navigation/view_models/navigation_view_model.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_area.dart';
import 'package:nai_casrand/ui/navigation/widgets/metadata_drop_area.dart';
import 'package:nai_casrand/ui/navigation/widgets/navigation_view.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';
import 'package:nai_casrand/ui/settings_page/widgets/settings_page_view.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _TestConfigService extends ConfigService {
  _TestConfigService() {
    packageInfo = PackageInfo(
      appName: 'NAI CasRand Forge',
      packageName: 'io.github.khkjdfkjhdsfakhds.casrandforge.beta',
      version: '1.0.0',
      buildNumber: '151',
    );
  }

  @override
  Future<void> saveConfig(Map<String, dynamic> jsonData) async {}
}

class _InMemoryAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;
  const _InMemoryAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}

void main() {
  late Map<String, dynamic> enTranslations;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    final jsonStr = File('assets/l10n/en.json').readAsStringSync();
    enTranslations = jsonDecode(jsonStr) as Map<String, dynamic>;
    await EasyLocalization.ensureInitialized();
  });

  setUp(() async {
    await GetIt.instance.reset();
    final payloadConfig = PayloadConfig(
      rootPromptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({
        'welcome_message_version': '1.0.0',
      }),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );
    GetIt.instance.registerSingleton<PayloadConfig>(payloadConfig);
    GetIt.instance.registerSingleton<CommandStatus>(CommandStatus());
    GetIt.instance.registerSingleton<NavigationRequest>(NavigationRequest());
    GetIt.instance.registerSingleton<GenerationPageViewmodel>(
      GenerationPageViewmodel(),
    );
    GetIt.instance.registerSingleton<ConfigService>(_TestConfigService());
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/l10n',
        assetLoader: _InMemoryAssetLoader(enTranslations),
        fallbackLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'ConfigPageView wraps both PromptTabView (with ignoreWhenTextEditing: true) and ParametersConfigView in ImageImportArea',
    (tester) async {
      await pumpHost(
        tester,
        ConfigPageView(viewmodel: ConfigPageViewmodel()),
      );

      // PromptTabView (Tab 0) is wrapped in ImageImportArea with ignoreWhenTextEditing: true
      expect(find.byType(PromptTabView), findsOneWidget);
      final promptImportFinder = find.ancestor(
        of: find.byType(PromptTabView),
        matching: find.byType(ImageImportArea),
      );
      expect(promptImportFinder, findsOneWidget);
      final promptImport = tester.widget<ImageImportArea>(promptImportFinder);
      expect(promptImport.ignoreWhenTextEditing, isTrue);

      // Switch to Parameters tab
      await tester.tap(find.text('Generation Parameters'));
      await tester.pumpAndSettle();

      expect(find.byType(ParametersConfigView), findsOneWidget);
      final paramImportFinder = find.ancestor(
        of: find.byType(ParametersConfigView),
        matching: find.byType(ImageImportArea),
      );
      expect(paramImportFinder, findsOneWidget);
      final paramImport = tester.widget<ImageImportArea>(paramImportFinder);
      expect(paramImport.ignoreWhenTextEditing, isTrue);
    },
  );

  testWidgets(
    'GenerationPageView contains an ImageImportArea self-contained with ignoreWhenTextEditing: false',
    (tester) async {
      await pumpHost(
        tester,
        GenerationPageView(viewmodel: GetIt.I()),
      );

      expect(find.byType(GenerationPageView), findsOneWidget);
      final genImportFinder = find.descendant(
        of: find.byType(GenerationPageView),
        matching: find.byType(ImageImportArea),
      );
      expect(genImportFinder, findsOneWidget);
      final genImport = tester.widget<ImageImportArea>(genImportFinder);
      expect(genImport.ignoreWhenTextEditing, isFalse);
    },
  );

  testWidgets(
    'NavigationView wraps Settings in ImageImportArea without a global drop wrapper',
    (tester) async {
      await pumpHost(
        tester,
        NavigationView(viewModel: NavigationViewModel()),
      );

      // Root does not wrap whole navigation shell in MetadataDropArea
      expect(
        find.ancestor(
          of: find.byType(NavigationView),
          matching: find.byType(MetadataDropArea),
        ),
        findsNothing,
      );

      // Settings destination has ImageImportArea
      GetIt.I<NavigationRequest>().goTo(AppDestination.settings);
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPageView), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(SettingsPageView),
          matching: find.byType(ImageImportArea),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'InfoDetailPage wraps Scaffold in ImageImportArea',
    (tester) async {
      await pumpHost(
        tester,
        InfoDetailPage(
          content: const InfoCardContent(
            title: 'Test Image Title',
            info: 'Prompt info',
            additionalInfo: {},
            imageBytes: null,
          ),
        ),
      );

      expect(find.byType(InfoDetailPage), findsOneWidget);
      final detailImportFinder = find.descendant(
        of: find.byType(InfoDetailPage),
        matching: find.byType(ImageImportArea),
      );
      expect(detailImportFinder, findsOneWidget);
    },
  );
}
