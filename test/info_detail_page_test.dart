import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

late Map<String, dynamic> testTranslations;

Uint8List solidPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(80, 120, 200));
  return Uint8List.fromList(img.encodePng(image));
}

InfoCardContent buildContent({Uint8List? bytes}) {
  return InfoCardContent(
    title: 'generated.png',
    info: '示例提示词:\n--角色: 1girl\n--内容: sunset',
    additionalInfo: const {
      'input': '1girl, sunset',
      'negative_prompt': 'low quality',
      'seed': 4242,
      'width': 832,
      'height': 1216,
      'steps': 36,
      'scale': 6.5,
      'sampler': 'k_dpmpp_2m',
      'noise_schedule': 'exponential',
      'cfg_rescale': 0.25,
      'variety_plus': true,
      'legacy_uc': true,
      'model': 'nai-diffusion-4-5-curated',
    },
    imageBytes: bytes,
  );
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
          strs: ['negative'],
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

  testWidgets('a wide window puts the image beside the prompt', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();

    final imageX = tester.getTopLeft(find.byType(Image).first).dx;
    final promptX = tester.getTopLeft(find.text('Prompt blocks').first).dx;
    expect(promptX, greaterThan(imageX),
        reason: 'the prompt column sits to the right of the image');
    // Both are visible at once, without scrolling.
    expect(find.text('Prompt blocks'), findsOneWidget);
  });

  testWidgets('a narrow window keeps the stacked layout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();

    final imageY = tester.getTopLeft(find.byType(Image).first).dy;
    final actionY =
        tester.getTopLeft(find.byKey(const Key('result-action-enhance'))).dy;
    expect(actionY, greaterThan(imageY),
        reason: 'the actions sit under the image on narrow windows');
    // The prompt card lives further down the same scrollable column.
    expect(
      find.text('Prompt blocks', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('an info-only result has no action bar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(InfoDetailPage(content: buildContent())),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ResultActionBar), findsNothing);
    expect(find.byKey(const Key('result-action-enhance')), findsNothing);
    // Falls back to the stacked layout when there is no image.
    expect(find.byType(VerticalDivider), findsNothing);
  });

  testWidgets('the action bar offers the kept actions only', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('result-action-enhance')), findsOneWidget);
    expect(find.byKey(const Key('result-action-base-image')), findsOneWidget);
    expect(find.byKey(const Key('result-action-inpaint')), findsOneWidget);
    expect(find.byKey(const Key('result-action-director')), findsOneWidget);
    // Generate Variations and Upscale are deliberately absent.
    expect(find.textContaining('Variation'), findsNothing);
    expect(find.textContaining('Upscale'), findsNothing);
  });

  testWidgets('space opens the fullscreen viewer and escape leaves it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fullscreen-image-viewer')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fullscreen-image-viewer')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fullscreen-image-viewer')), findsNothing);
  });

  testWidgets('space also closes the fullscreen viewer', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fullscreen-image-viewer')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fullscreen-image-viewer')), findsNothing);
  });

  testWidgets('enhance carries the complete profile to the Enhance page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    final navigation = GetIt.I<NavigationRequest>();
    payloadConfig.randomProfile.paramConfig
      ..steps = 17
      ..scale = 4.0
      ..randomSeed = true
      ..seed = 42;

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('result-action-enhance'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();

    // Enhance has its own source image; the Img2Img base stays untouched.
    expect(payloadConfig.enhanceConfig.hasImage, isTrue);
    expect(payloadConfig.i2iConfig.hasImage, isFalse);
    expect(payloadConfig.overridePrompt, '1girl, sunset');
    expect(payloadConfig.useOverridePrompt, isTrue);
    expect(payloadConfig.paramConfig.seed, 4242);
    expect(payloadConfig.paramConfig.randomSeed, isFalse);
    expect(payloadConfig.paramConfig.steps, 36);
    expect(payloadConfig.paramConfig.scale, 6.5);
    expect(payloadConfig.paramConfig.sampler, 'k_dpmpp_2m');
    expect(payloadConfig.paramConfig.noiseSchedule, 'exponential');
    expect(payloadConfig.paramConfig.cfgRescale, 0.25);
    expect(payloadConfig.paramConfig.varietyPlus, isTrue);
    expect(payloadConfig.paramConfig.legacyUc, isTrue);
    expect(payloadConfig.paramConfig.model, 'nai-diffusion-4-5-curated');
    expect(payloadConfig.negativePromptConfig.strs, ['low quality']);
    expect(payloadConfig.randomProfile.paramConfig.steps, 17);
    expect(payloadConfig.randomProfile.paramConfig.scale, 4.0);
    expect(payloadConfig.randomProfile.paramConfig.randomSeed, isTrue);
    expect(payloadConfig.randomProfile.paramConfig.seed, 42);
    expect(navigation.requestedDestination.value, AppDestination.enhance);
  });

  testWidgets('use as base image does not touch the prompt or seed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    final navigation = GetIt.I<NavigationRequest>();

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('result-action-base-image'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();

    expect(payloadConfig.i2iConfig.hasImage, isTrue);
    expect(payloadConfig.useOverridePrompt, isFalse);
    expect(payloadConfig.paramConfig.randomSeed, isTrue);
    expect(navigation.i2iEntryMode, I2iEntryMode.baseImage);
  });

  testWidgets('director tools receives the image and its own entry mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    final navigation = GetIt.I<NavigationRequest>();

    await tester.pumpWidget(
      localizedApp(
          InfoDetailPage(content: buildContent(bytes: solidPng(64, 96)))),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('result-action-director'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();

    expect(payloadConfig.directorToolConfig.hasImage, isTrue);
    // Director Tools works on its own source, not the img2img base image.
    expect(payloadConfig.i2iConfig.hasImage, isFalse);
    // It is its own destination, not a section of the Img2Img page.
    expect(navigation.requestedDestination.value, AppDestination.directorTools);
  });
}
