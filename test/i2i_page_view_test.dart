import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart' show CropRect;
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';
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

  testWidgets('I2I page keeps controls visible and only disables generation', (
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
    expect(find.byKey(const Key('inpaint-edit-mask')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('inpaint-edit-mask')),
          )
          .onPressed,
      isNotNull,
    );
    final generate = tester.widget<FilledButton>(
      find.byKey(const Key('i2i-generate-once')),
    );
    expect(generate.onPressed, isNull);
    expect(find.text('Img2Img Parameters'), findsOneWidget);
  });

  testWidgets('inpaint action overlays the top-right of the import area', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    final importArea = tester.getRect(
      find.byKey(const Key('i2i-import-image-area')),
    );
    final inpaintAction = tester.getRect(
      find.byKey(const Key('inpaint-edit-mask')),
    );

    expect(inpaintAction.left, greaterThan(importArea.center.dx));
    expect(inpaintAction.top, greaterThanOrEqualTo(importArea.top));
    expect(inpaintAction.right, lessThan(importArea.right));
    expect(inpaintAction.center.dy, lessThan(importArea.center.dy));
    expect(
      inpaintAction.top,
      lessThan(tester.getTopLeft(find.text('Img2Img Parameters')).dy),
    );
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
    // The only Inpaint entry is the top-right overlay.
    expect(find.text('Inpaint'), findsOneWidget);
    expect(find.text('No mask: plain img2img'), findsNothing);
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
    expect(find.text('Inpaint'), findsOneWidget);
    expect(
        find.text('Mask painted: masked area will be repainted'), findsNothing);
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

    final clearButton = tester.widget<FilledButton>(
      find.byKey(const Key('inpaint-clear-mask')),
    );
    expect(clearButton.onPressed, isNotNull);
    clearButton.onPressed!();
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
    final generate = tester.widget<FilledButton>(
      find.byKey(const Key('i2i-generate-once')),
    );
    expect(generate.onPressed, isNull);
    expect(find.text('Img2Img Parameters'), findsOneWidget);
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

    // 500 -> 512, 300 -> 320 (nearest multiple of 64). The button switches
    // mode even when Auto happened to choose the same dimensions.
    expect(
      payloadConfig.i2iConfig.requestSize,
      const GenerationSize(width: 512, height: 320),
    );
    expect(
      payloadConfig.paramConfig.sizes,
      [const GenerationSize(width: 832, height: 1216)],
    );
    expect(
      payloadConfig.i2iConfig.sizeMode,
      I2iSizeMode.original,
    );
    expect(find.byKey(const Key('i2i-use-image-size')), findsOneWidget);
  });

  testWidgets('manual size dialog snaps and applies the request size', (
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

    final manualButton = find.byKey(const Key('i2i-manual-size'));
    await tester.ensureVisible(manualButton);
    await tester.tap(manualButton);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('i2i-manual-size-width')),
      '900',
    );
    await tester.enterText(
      find.byKey(const Key('i2i-manual-size-height')),
      '1250',
    );
    await tester.tap(find.byKey(const Key('i2i-manual-size-confirm')));
    await tester.pumpAndSettle();

    // 900 -> 896, 1250 -> 1280 (nearest multiples of 64).
    expect(
      payloadConfig.i2iConfig.requestSize,
      const GenerationSize(width: 896, height: 1280),
    );
    expect(
      payloadConfig.paramConfig.sizes,
      [const GenerationSize(width: 832, height: 1216)],
    );
  });

  testWidgets(
      'generation action buttons share a compact width and expand on hover',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(
        GenerationPageView(viewmodel: GetIt.I<GenerationPageViewmodel>()),
      ),
    );
    await tester.pumpAndSettle();

    final actionKeys = [
      const Key('generation-settings-fab'),
      const Key('prompt-mode-switch'),
      const Key('generate-prompt-fab'),
      const Key('generation-toggle-fab'),
    ];
    final collapsedWidths =
        actionKeys.map((key) => tester.getSize(find.byKey(key)).width).toList();
    expect(collapsedWidths.toSet(), hasLength(1));

    final settings = find.byKey(const Key('generation-settings-fab'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(settings));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(settings).width,
      greaterThan(collapsedWidths.first),
    );
    expect(find.text('Generation Settings'), findsWidgets);
    await mouse.removePointer();
  });

  testWidgets('a manual focus frame replaces the autocrop switch', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().i2iConfig;
    config.setImage(solidPng(500, 300));
    config.setMask(maskPng(500, 300), const <MaskStroke>[]);
    config.setManualFocusFrame(
      const CropRect(x: 0, y: 0, w: 128, h: 128),
    );

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inpaint-manual-frame')), findsOneWidget);
    expect(find.byKey(const Key('inpaint-autocrop')), findsNothing);
    expect(find.textContaining('128 × 128'), findsOneWidget);

    final clearButton = find.byKey(const Key('inpaint-clear-frame'));
    await tester.ensureVisible(clearButton);
    await tester.tap(clearButton);
    await tester.pumpAndSettle();

    expect(config.manualFocusFrame, isNull);
    expect(find.byKey(const Key('inpaint-autocrop')), findsOneWidget);
  });

  testWidgets('saved mask and Focus frame are overlaid on the base preview', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().i2iConfig;
    config.setImage(solidPng(500, 300));
    config.setMask(
      solidPng(500, 300),
      const [
        MaskStroke(
          isErase: false,
          brushSize: 40,
          points: [Offset(100, 100), Offset(180, 140)],
        ),
      ],
    );
    config.setManualFocusFrame(const CropRect(x: 60, y: 40, w: 260, h: 180));

    await tester.pumpWidget(
      localizedApp(I2iPageView(viewmodel: I2iPageViewmodel())),
    );
    await tester.pumpAndSettle();

    final previewSize = tester.getSize(
      find.byKey(const Key('i2i-image-preview-stack')),
    );
    expect(previewSize.width / previewSize.height, closeTo(500 / 300, 0.001));
    expect(
      find.byKey(const Key('i2i-mask-preview-overlay')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('inpaint-manual-frame')), findsOneWidget);

    await tester.tap(find.byKey(const Key('inpaint-clear-mask')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('i2i-mask-preview-overlay')),
      findsNothing,
    );
    expect(config.manualFocusFrame, isNull);
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
