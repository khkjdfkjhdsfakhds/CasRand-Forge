import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/vibe_config/view_models/vibe_config_list_viewmodel.dart';

import 'drop_test_fakes.dart';

class _TestAssetLoader extends AssetLoader {
  const _TestAssetLoader(this.translations);

  final Map<String, dynamic> translations;

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}

void main() {
  late Map<String, dynamic> translations;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    translations = jsonDecode(
      await rootBundle.loadString('assets/l10n/en.json'),
    ) as Map<String, dynamic>;
  });

  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton(
      PayloadConfig(
        rootPromptConfig: PromptConfig(strs: [], prompts: []),
        negativePromptConfig: PromptConfig(strs: [], prompts: []),
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

  tearDown(() => GetIt.I.reset());

  testWidgets('legacy Vibe drop read failure is visible and preserves state', (
    tester,
  ) async {
    late BuildContext pageContext;
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'test',
        assetLoader: _TestAssetLoader(translations),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        saveLocale: false,
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(
              body: Builder(builder: (context) {
                pageContext = context;
                return const SizedBox();
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewmodel = VibeConfigListViewmodel();

    await viewmodel.handleVibeDropEvent(pageContext, failingImageDropEvent());
    await tester.pump();

    expect(find.textContaining('Could not add Vibe reference'), findsOneWidget);
    expect(viewmodel.vibeList, isEmpty);
  });
}
