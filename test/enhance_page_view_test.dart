import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/enhance_page/view_models/enhance_page_viewmodel.dart';
import 'package:nai_casrand/ui/enhance_page/widgets/enhance_page_view.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

class _RecordingGenerationViewmodel extends GenerationPageViewmodel {
  int enhanceRuns = 0;

  @override
  Future<bool> runEnhanceGeneration() async {
    enhanceRuns++;
    return true;
  }
}

late Map<String, dynamic> testTranslations;

Uint8List solidPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(60, 90, 150));
  return Uint8List.fromList(img.encodePng(image));
}

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
        paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
          randomSeed: true,
          seed: 42,
        ),
        settings: Settings.fromJson({}),
        overridePrompt: '',
        useOverridePrompt: false,
        useCharacterPromptWithOverride: false,
      ),
    );
    GetIt.instance.registerSingleton<GenerationPageViewmodel>(
      _RecordingGenerationViewmodel(),
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

  testWidgets('without a source image workspace and controls stay visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(EnhancePageView(viewmodel: EnhancePageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enhance-import-image-area')), findsOneWidget);
    expect(find.byKey(const Key('transform-original-stage')), findsOneWidget);
    expect(find.byKey(const Key('transform-result-stage')), findsOneWidget);
    expect(find.byKey(const Key('enhance-preset-slider')), findsOneWidget);
    expect(find.byKey(const Key('enhance-show-individual')), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('enhance-show-individual')),
          )
          .onChanged,
      isNotNull,
    );
    final run = tester.widget<FilledButton>(
      find.byKey(const Key('enhance-run')),
    );
    expect(run.onPressed, isNull);
    // No locked-feature placeholder anywhere.
    expect(find.textContaining('unlock'), findsNothing);
  });

  testWidgets('individual Enhance settings expose real strength and noise', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().enhanceConfig;
    config.setImage(solidPng(512, 512));

    await tester.pumpWidget(
      localizedApp(EnhancePageView(viewmodel: EnhancePageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enhance-strength')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const Key('enhance-show-individual')),
    );
    await tester.tap(find.byKey(const Key('enhance-show-individual')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enhance-strength')), findsOneWidget);
    expect(find.byKey(const Key('enhance-noise')), findsOneWidget);
    expect(config.showIndividualSettings, isTrue);
    expect(config.strength, config.individualStrength);
    expect(config.noise, config.individualNoise);
  });

  testWidgets('a small source offers 1x, 1.5x and 2x', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GetIt.I<PayloadConfig>().enhanceConfig.setImage(solidPng(512, 512));

    await tester.pumpWidget(
      localizedApp(EnhancePageView(viewmodel: EnhancePageViewmodel())),
    );
    await tester.pumpAndSettle();

    // A small image fits the budget even at 2x, like the official panel.
    expect(find.byKey(const Key('enhance-scale-1.0')), findsOneWidget);
    expect(find.byKey(const Key('enhance-scale-1.5')), findsOneWidget);
    expect(find.byKey(const Key('enhance-scale-2.0')), findsOneWidget);
    expect(find.text('1.5x  768×768'), findsOneWidget);
    expect(find.text('2.0x  1024×1024'), findsOneWidget);
    expect(find.byKey(const Key('enhance-preset-slider')), findsOneWidget);
    // The run button carries the target size and the Anlas estimate.
    expect(find.byKey(const Key('enhance-run')), findsOneWidget);
    expect(find.textContaining('Enhance once → 1024×1024'), findsOneWidget);
    expect(find.textContaining('·'), findsWidgets);
  });

  testWidgets('a typical portrait offers 1.5x but not 2x', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GetIt.I<PayloadConfig>().enhanceConfig.setImage(solidPng(832, 1216));

    await tester.pumpWidget(
      localizedApp(EnhancePageView(viewmodel: EnhancePageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enhance-scale-1.0')), findsOneWidget);
    expect(find.byKey(const Key('enhance-scale-1.5')), findsOneWidget);
    // 1664x2432 would blow the request budget.
    expect(find.byKey(const Key('enhance-scale-2.0')), findsNothing);
  });

  testWidgets('scale 1.5x vanishes when the source is already at the cap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().enhanceConfig;
    config.setImage(solidPng(1728, 1728));

    await tester.pumpWidget(
      localizedApp(EnhancePageView(viewmodel: EnhancePageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enhance-scale-1.0')), findsOneWidget);
    expect(find.byKey(const Key('enhance-scale-1.5')), findsNothing);
    // The default 1.5x is no longer available, so the config fell back to
    // the largest option that still fits.
    expect(config.scale, 1.0);
  });

  testWidgets('running Enhance goes through its own chain, not Img2Img', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.enhanceConfig.setImage(solidPng(512, 512));
    final generationViewmodel =
        GetIt.I<GenerationPageViewmodel>() as _RecordingGenerationViewmodel;

    final viewmodel = EnhancePageViewmodel();
    await tester
        .pumpWidget(localizedApp(EnhancePageView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();

    final scaleChip = find.byKey(const Key('enhance-scale-1.5'));
    await tester.ensureVisible(scaleChip);
    await tester.tap(scaleChip);
    await tester.pumpAndSettle();
    viewmodel.setPresetIndex(4);
    await tester.pumpAndSettle();

    final runButton = find.byKey(const Key('enhance-run'));
    await tester.ensureVisible(runButton);
    await tester.tap(runButton);
    await tester.pumpAndSettle();

    expect(generationViewmodel.enhanceRuns, 1);
    // The independent chain leaves the Img2Img config and the generation
    // sizes untouched.
    expect(payloadConfig.i2iConfig.hasImage, isFalse);
    expect(
      payloadConfig.paramConfig.sizes,
      [const GenerationSize(width: 832, height: 1216)],
    );
    expect(payloadConfig.enhanceConfig.scale, 1.5);
    expect(payloadConfig.enhanceConfig.presetIndex, 4);
  });

  testWidgets('use base image pulls the Img2Img base over', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.i2iConfig.setImage(solidPng(320, 320));

    await tester.pumpWidget(
      localizedApp(EnhancePageView(viewmodel: EnhancePageViewmodel())),
    );
    await tester.pumpAndSettle();

    final useBase = find.byKey(const Key('enhance-use-base-image'));
    expect(useBase, findsOneWidget);
    await tester.tap(useBase);
    await tester.pumpAndSettle();

    expect(payloadConfig.enhanceConfig.hasImage, isTrue);
    expect(payloadConfig.enhanceConfig.width, 320);
  });
}
