import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/widgets/classic_info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_page_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_settings_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/i2i_page/view_models/i2i_page_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/i2i_page_view.dart';
import 'package:flutter_command/flutter_command.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

class _NoNetworkGenerationPageViewmodel extends GenerationPageViewmodel {
  @override
  void nextCommand() {}
}

late Map<String, dynamic> testTranslations;

Uint8List solidPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(120, 30, 30));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List maskPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fillRect(
    image,
    x1: 10,
    y1: 10,
    x2: 40,
    y2: 40,
    color: img.ColorRgb8(255, 255, 255),
  );
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
      _NoNetworkGenerationPageViewmodel(),
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

  testWidgets('I2I page shows only the import area without a base image', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('i2i-import-image-area')), findsOneWidget);
    expect(find.text('Base Image'), findsOneWidget);
    // Parameter, inpaint and action cards stay hidden until an image exists.
    expect(find.byKey(const Key('inpaint-edit-mask')), findsNothing);
    expect(find.byKey(const Key('i2i-generate-once')), findsNothing);
    expect(find.text('Img2Img Parameters'), findsNothing);
  });

  testWidgets('base image reveals parameters, inpaint entry and generate', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.i2iConfig.setImage(solidPng(500, 300));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.text('500 × 300'), findsOneWidget);
    expect(find.text('Img2Img Parameters'), findsOneWidget);
    expect(find.byKey(const Key('inpaint-edit-mask')), findsOneWidget);
    expect(find.byKey(const Key('i2i-generate-once')), findsOneWidget);
    expect(find.textContaining('Strength: 0.70'), findsOneWidget);
    expect(find.textContaining('Noise: 0.00'), findsOneWidget);
    // Inpaint-only switches stay hidden until a mask exists.
    expect(find.byKey(const Key('inpaint-autocrop')), findsNothing);
    expect(find.text('No mask: plain img2img'), findsOneWidget);
  });

  testWidgets('mask presence swaps noise for the inpaint switches', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().i2iConfig;
    config.setImage(solidPng(500, 300));
    config.setMask(maskPng(500, 300), const <MaskStroke>[]);

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inpaint-autocrop')), findsOneWidget);
    expect(
      find.byKey(const Key('inpaint-add-original-image')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('inpaint-clear-mask')), findsOneWidget);
    expect(find.textContaining('Noise:'), findsNothing);
    expect(
      find.text('Mask painted: masked area will be repainted'),
      findsOneWidget,
    );
  });

  testWidgets('autocrop switch toggles the config and its hint', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().i2iConfig;
    config.setImage(solidPng(500, 300));
    config.setMask(maskPng(500, 300), const <MaskStroke>[]);

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(config.autocropEnabled, isTrue);
    final autocropSwitch = find.byKey(const Key('inpaint-autocrop'));
    await tester.ensureVisible(autocropSwitch);
    await tester.tap(autocropSwitch);
    await tester.pumpAndSettle();

    expect(config.autocropEnabled, isFalse);
    expect(
      find.textContaining('the whole image is scaled'),
      findsOneWidget,
    );
  });

  testWidgets('clearing the mask returns the page to plain img2img', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().i2iConfig;
    config.setImage(solidPng(500, 300));
    config.setMask(maskPng(500, 300), const <MaskStroke>[]);

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('inpaint-clear-mask')));
    await tester.pumpAndSettle();

    expect(config.hasMask, isFalse);
    expect(find.byKey(const Key('inpaint-autocrop')), findsNothing);
    expect(find.textContaining('Noise:'), findsOneWidget);
  });

  testWidgets('removing the base image collapses the page again', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().i2iConfig;
    config.setImage(solidPng(500, 300));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('i2i-remove-image-button')));
    await tester.pumpAndSettle();

    expect(config.hasImage, isFalse);
    expect(find.text('Img2Img Parameters'), findsNothing);
    expect(find.byKey(const Key('i2i-generate-once')), findsNothing);
  });

  testWidgets('use image size applies the snapped size to parameters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.i2iConfig.setImage(solidPng(500, 300));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    final useSizeButton = find.byKey(const Key('i2i-use-image-size'));
    await tester.ensureVisible(useSizeButton);
    await tester.tap(useSizeButton);
    await tester.pumpAndSettle();

    // 500 -> 512, 300 -> 320 (nearest multiple of 64).
    expect(
      payloadConfig.paramConfig.sizes,
      [const GenerationSize(width: 512, height: 320)],
    );
    expect(find.byKey(const Key('i2i-use-image-size')), findsNothing);
  });

  testWidgets('enhance section offers magnifications and a preset', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GetIt.I<PayloadConfig>().i2iConfig.setImage(solidPng(512, 512));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enhance'), findsOneWidget);
    // The official panel offers 1x and 1.5x only.
    expect(find.byKey(const Key('enhance-scale-1.0')), findsOneWidget);
    expect(find.byKey(const Key('enhance-scale-1.5')), findsOneWidget);
    expect(find.byKey(const Key('enhance-scale-2.0')), findsNothing);
    expect(find.text('1.5x  768×768'), findsOneWidget);
    expect(find.byKey(const Key('enhance-preset-slider')), findsOneWidget);
    expect(find.byKey(const Key('enhance-run')), findsOneWidget);
    expect(find.textContaining('Enhance once → 768×768'), findsOneWidget);
  });

  testWidgets('enhance applies the target size, preset and clears the mask', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    final config = payloadConfig.i2iConfig;
    config.setImage(solidPng(512, 512));
    config.setMask(maskPng(512, 512), const <MaskStroke>[]);

    final viewmodel = I2iPageViewmodel();
    await tester.pumpWidget(localizedApp(I2iPageView(viewmodel: viewmodel)));
    await tester.pumpAndSettle();

    // Pick 1.5x and the strongest magnitude, then run.
    final scaleChip = find.byKey(const Key('enhance-scale-1.5'));
    await tester.ensureVisible(scaleChip);
    await tester.tap(scaleChip);
    await tester.pumpAndSettle();
    viewmodel.setEnhancePresetIndex(4);
    await tester.pumpAndSettle();

    final runButton = find.byKey(const Key('enhance-run'));
    await tester.ensureVisible(runButton);
    await tester.tap(runButton);
    await tester.pumpAndSettle();

    // 512 * 1.5 = 768, already a multiple of 64.
    expect(
      payloadConfig.paramConfig.sizes,
      [const GenerationSize(width: 768, height: 768)],
    );
    expect(config.strength, 0.7);
    expect(config.noise, 0.1);
    expect(config.hasMask, isFalse, reason: 'enhance re-renders the whole image');
  });

  testWidgets('enhance offers nothing when the image is already at the cap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 1728x1728 is exactly the cap, so 1x is offered but 1.5x is not.
    GetIt.I<PayloadConfig>().i2iConfig.setImage(solidPng(1728, 1728));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enhance-scale-1.0')), findsOneWidget);
    expect(find.byKey(const Key('enhance-scale-1.5')), findsNothing);
  });

  testWidgets('display mode switch changes the result card widget', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewmodel = GetIt.I<GenerationPageViewmodel>();
    viewmodel.addAndRunCommand(
      Command.createAsyncNoParam(
        () async => const InfoCardContent(
          title: 'result',
          info: 'prompt text',
          additionalInfo: {'input': 'prompt text'},
        ),
        initialValue: InfoCardContent.fromEmpty(),
      ),
    );

    await tester.pumpWidget(
      localizedApp(GenerationPageView(viewmodel: viewmodel)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(InfoCard), findsOneWidget);
    expect(find.byType(ClassicInfoCard), findsNothing);

    viewmodel.setResultDisplayMode('classic');
    await tester.pumpAndSettle();

    expect(find.byType(ClassicInfoCard), findsOneWidget);
    expect(find.byType(InfoCard), findsNothing);
    expect(
      GetIt.I<PayloadConfig>().settings.resultDisplayMode,
      'classic',
    );
  });

  testWidgets('generation settings expose the display mode selector', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final viewmodel = GetIt.I<GenerationPageViewmodel>();

    await tester.pumpWidget(
      localizedApp(
        Scaffold(body: GenerationSettingsView(viewmodel: viewmodel)),
      ),
    );
    await tester.pumpAndSettle();

    final selector = find.byKey(const Key('generation-settings-display-mode'));
    expect(selector, findsOneWidget);
    await tester.ensureVisible(selector);
    await tester.tap(find.text('Classic grid'));
    await tester.pumpAndSettle();

    expect(
      GetIt.I<PayloadConfig>().settings.resultDisplayMode,
      'classic',
    );
  });

  testWidgets('classic card shows the per-block prompt and Anlas cost', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final command = Command.createAsyncNoParam(
      () async => InfoCardContent(
        title: 'generated.png',
        // The comment carries the per-block breakdown the card must show.
        info: '示例提示词:\n--角色: 1girl\n--内容: sunset over the sea',
        additionalInfo: const {'input': '1girl, sunset over the sea'},
        imageBytes: solidPng(64, 64),
        anlasCost: 21,
        anlasRemaining: 4979,
        tokenLabel: 'Token B',
      ),
      initialValue: InfoCardContent.fromEmpty(),
    );
    command();
    await tester.pump();

    await tester.pumpWidget(
      localizedApp(
        Scaffold(
          body: SizedBox(
            width: 600,
            height: 300,
            child: ClassicInfoCard(command: command),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('generated.png'), findsOneWidget);
    expect(
      find.text('示例提示词:\n--角色: 1girl\n--内容: sunset over the sea'),
      findsOneWidget,
      reason: 'the card shows the per-block breakdown, not the flat prompt',
    );
    expect(find.text('Spent 21 Anlas · 4979 left'), findsOneWidget);
    expect(find.text('Token B'), findsOneWidget);
  });
}
