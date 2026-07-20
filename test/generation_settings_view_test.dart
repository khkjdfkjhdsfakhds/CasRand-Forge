import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/config_page/widgets/config_page_view.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_page_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_settings_view.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/settings_page/widgets/settings_page_view.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

late Map<String, dynamic> testTranslations;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    final source = await rootBundle.loadString('assets/l10n/en.json');
    testTranslations = jsonDecode(source) as Map<String, dynamic>;
  });

  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton(CommandStatus());
    GetIt.instance.registerSingleton(
      PayloadConfig(
        rootPromptConfig: PromptConfig(strs: [], prompts: []),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
          randomSeed: true,
          seed: 42,
        ),
        settings: Settings.fromJson({
          'generation_count': 0,
          'generation_interval': 10,
        }),
        overridePrompt: '',
        useOverridePrompt: false,
        useCharacterPromptWithOverride: false,
      ),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  Widget localizedApp(Widget home) {
    return EasyLocalization(
      key: UniqueKey(),
      supportedLocales: const [Locale('en')],
      path: 'test',
      assetLoader: _TestAssetLoader(testTranslations),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: home,
        ),
      ),
    );
  }

  testWidgets('moved settings appear together on the generation page', (
    tester,
  ) async {
    final viewmodel = GenerationPageViewmodel();
    await tester.pumpWidget(
      localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Image Size (W × H)'), findsOneWidget);
    expect(find.text('Use Random Seed'), findsOneWidget);
    expect(find.text('Generation count'), findsOneWidget);
    expect(find.text('Generation interval (seconds)'), findsOneWidget);
    expect(find.text('Batch settings'), findsNothing);
    expect(find.text('Random Seed'), findsNothing);
    expect(find.text('Override random prompts'), findsNothing);
    expect(find.text('Use generated character prompts'), findsNothing);

    final orderedSettings = [
      find.text('Generation count'),
      find.text('Generation interval (seconds)'),
      find.text('Image Size (W × H)'),
      find.text('Use Random Seed'),
      find.text('Number of columns: 2'),
    ];
    final verticalOffsets =
        orderedSettings.map((finder) => tester.getTopLeft(finder).dy).toList();
    expect(verticalOffsets, orderedEquals(List.of(verticalOffsets)..sort()));

    await tester.tap(
      find.byKey(const Key('generation-settings-random-seed')),
    );
    await tester.pump();

    expect(GetIt.I<PayloadConfig>().paramConfig.randomSeed, isFalse);
    expect(find.text('Random Seed'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Random Seed')).dy,
      lessThan(tester.getTopLeft(find.text('Number of columns: 2')).dy),
    );

    expect(find.text('Request per batch'), findsNothing);
    expect(find.text('Interval between batches (seconds)'), findsNothing);
  });

  testWidgets('override prompt settings stay hidden without clearing data', (
    tester,
  ) async {
    final config = GetIt.I<PayloadConfig>();
    config.useOverridePrompt = true;
    config.useCharacterPromptWithOverride = true;
    config.overridePrompt = 'preserved prompt';

    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: GenerationSettingsView(viewmodel: GenerationPageViewmodel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Override random prompts'), findsNothing);
    expect(find.text('Use generated character prompts'), findsNothing);
    expect(config.useOverridePrompt, isTrue);
    expect(config.useCharacterPromptWithOverride, isTrue);
    expect(config.overridePrompt, 'preserved prompt');
  });

  testWidgets('previously enabled override prompt fields stay hidden', (
    tester,
  ) async {
    final config = GetIt.I<PayloadConfig>();
    config.useOverridePrompt = true;
    config.overridePrompt = 'preserved prompt';

    await tester.pumpWidget(
      localizedApp(
        GenerationPageView(viewmodel: GenerationPageViewmodel()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Override prompts'), findsNothing);
    expect(find.text('Unwanted content'), findsNothing);
    expect(config.useOverridePrompt, isTrue);
    expect(config.overridePrompt, 'preserved prompt');
  });

  testWidgets('image size selector still supports preset and manual sizes', (
    tester,
  ) async {
    final viewmodel = GenerationPageViewmodel();
    await tester.pumpWidget(
      localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('generation-settings-image-size')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Selected sizes'), findsOneWidget);
    expect(find.text('Preset sizes'), findsOneWidget);
    expect(find.text('Enter a custom size'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('manual-size-width')),
      '833',
    );
    await tester.enterText(
      find.byKey(const Key('manual-size-height')),
      '1217',
    );
    await tester.tap(find.byKey(const Key('manual-size-add')));
    await tester.pump();

    expect(find.text('896 × 1280'), findsOneWidget);
  });

  testWidgets('old pages no longer expose the moved settings', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        ParametersConfigView(viewmodel: ParametersConfigViewmodel()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Image Size (W × H)'), findsNothing);
    expect(find.text('Use Random Seed'), findsNothing);

    await tester.pumpWidget(localizedApp(SettingsPageView()));
    await tester.pumpAndSettle();

    expect(find.text('Batch settings'), findsNothing);
  });

  testWidgets('Vibe Transfer and Generation Parameters keep their order', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        ConfigPageView(viewmodel: ConfigPageViewmodel()),
      ),
    );
    await tester.pumpAndSettle();

    final labels = tester
        .widgetList<Tab>(find.byType(Tab))
        .map((tab) => tab.text)
        .toList();
    expect(
      labels,
      ['Prompt Config', 'Vibe Transfer', 'Generation Parameters'],
    );
  });
}
