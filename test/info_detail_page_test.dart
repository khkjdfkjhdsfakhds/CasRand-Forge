import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_page_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

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

class _GalleryRefreshViewmodel extends GenerationPageViewmodel {
  void notifyGalleryChanged() => notifyListeners();
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
    final payloadConfig = PayloadConfig(
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
    );
    GetIt.instance.registerSingleton(payloadConfig);
    GetIt.instance.registerSingleton(
      ImageHandoffCoordinator(
        payloadConfig: payloadConfig,
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (bytes) async {
          final image = img.decodeImage(bytes)!;
          return ImageDimensions(width: image.width, height: image.height);
        },
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

  testWidgets('key parameters show predicted then settled Opus usage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final predicted = InfoCardContent(
      title: 'v5.png',
      info: 'prompt',
      additionalInfo: const {
        'width': 832,
        'height': 1216,
        'model': 'nai-diffusion-5-full',
      },
      imageBytes: solidPng(64, 96),
      opusUsage: OpusUsage(
        percent: 73,
        isNegative: false,
        secondsPerPercent: 6048,
        observedAt: DateTime(2026, 8, 21),
      ),
      opusUsageIsEstimated: true,
      opusUsageSettling: true,
    );

    await tester.pumpWidget(localizedApp(InfoDetailPage(content: predicted)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('opus-usage-limit-bar')), findsOneWidget);
    expect(find.textContaining('Estimated'), findsWidgets);
    expect(find.textContaining('73%'), findsOneWidget);

    final settled = predicted.copyWith(
      opusUsage: OpusUsage(
        percent: 72,
        isNegative: false,
        secondsPerPercent: 6048,
        observedAt: DateTime(2026, 8, 21),
      ),
      opusUsageIsEstimated: false,
      opusUsageSettling: false,
    );
    await tester.pumpWidget(localizedApp(InfoDetailPage(content: settled)));
    await tester.pumpAndSettle();

    expect(find.textContaining('72%'), findsOneWidget);
    expect(find.textContaining('Actual'), findsWidgets);
  });

  testWidgets('Opus usage keeps boosted percentages above 100%',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final boosted = InfoCardContent(
      title: 'v5-boosted.png',
      info: 'prompt',
      additionalInfo: const {
        'width': 832,
        'height': 1216,
        'model': 'nai-diffusion-5-full',
      },
      imageBytes: solidPng(64, 96),
      opusUsage: OpusUsage(
        percent: 170,
        isNegative: false,
        secondsPerPercent: 6048,
        observedAt: DateTime(2026, 8, 21),
      ),
    );

    await tester.pumpWidget(localizedApp(InfoDetailPage(content: boosted)));
    await tester.pumpAndSettle();

    expect(find.textContaining('170%'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, 1);
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

  testWidgets('gallery arrows switch the image and matching information', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var reportedIndex = 0;
    final second = InfoCardContent(
      title: 'second.png',
      info: 'second block prompt',
      additionalInfo: const {
        'input': 'second final prompt',
        'negative_prompt': 'second negative',
        'seed': 2,
        'width': 64,
        'height': 96,
      },
      imageBytes: solidPng(64, 96),
    );

    await tester.pumpWidget(
      localizedApp(
        InfoDetailPage.gallery(
          contents: [
            buildContent(bytes: solidPng(64, 96)),
            second,
          ],
          initialIndex: 0,
          onIndexChanged: (index) => reportedIndex = index,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.byKey(const Key('detail-gallery-previous')), findsNothing);
    expect(find.byKey(const Key('detail-gallery-next')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(reportedIndex, 1);
    expect(find.text('second.png'), findsOneWidget);
    expect(find.text('second block prompt'), findsOneWidget);
    expect(find.text('second final prompt'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.byKey(const Key('detail-gallery-previous')), findsOneWidget);
    expect(find.byKey(const Key('detail-gallery-next')), findsNothing);
  });

  testWidgets('horizontal swipe switches gallery items on touch layouts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var reportedIndex = 0;

    await tester.pumpWidget(
      localizedApp(
        InfoDetailPage.gallery(
          contents: [
            buildContent(bytes: solidPng(64, 96)),
            InfoCardContent(
              title: 'swiped.png',
              info: 'swiped info',
              additionalInfo: const {'seed': 9},
              imageBytes: solidPng(64, 96),
            ),
          ],
          initialIndex: 0,
          onIndexChanged: (index) => reportedIndex = index,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byKey(const Key('detail-gallery-swipe-target')),
      const Offset(-420, 0),
      1200,
    );
    await tester.pumpAndSettle();

    expect(reportedIndex, 1);
    expect(find.text('swiped.png'), findsOneWidget);
    expect(find.text('swiped info'), findsOneWidget);
  });

  testWidgets('newly generated results appear in the open gallery', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.settings.generationPageColumnCount = 1;
    payloadConfig.settings.resultDisplayMode = 'classic';
    final commandStatus = GetIt.I<CommandStatus>();
    for (var index = 0; index < 2; index++) {
      final content = InfoCardContent(
        title: 'item$index.png',
        info: 'prompt $index',
        additionalInfo: {'seed': index},
        imageBytes: solidPng(64, 96),
      );
      commandStatus.commandList.add(
        Command.createAsyncNoParam(
          () async => content,
          initialValue: content,
        ),
      );
    }
    final viewmodel = _GalleryRefreshViewmodel();
    addTearDown(viewmodel.dispose);

    await tester.pumpWidget(
      localizedApp(GenerationPageView(viewmodel: viewmodel)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('item1.png'));
    await tester.pumpAndSettle();

    // The newest result is at the start of the newest-first gallery order.
    expect(find.byKey(const Key('detail-gallery-previous')), findsNothing);
    expect(find.byKey(const Key('detail-gallery-next')), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);

    final generated = InfoCardContent(
      title: 'item2.png',
      info: 'prompt 2',
      additionalInfo: {'seed': 2},
      imageBytes: solidPng(64, 96),
    );
    commandStatus.commandList.add(
      Command.createAsyncNoParam(
        () async => generated,
        initialValue: generated,
      ),
    );
    viewmodel.notifyGalleryChanged();
    await tester.pump();

    // The new image is prepended, so the left arrow appears without leaving
    // the page and the currently viewed image stays selected.
    expect(find.byKey(const Key('detail-gallery-previous')), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.text('item1.png'), findsOneWidget);

    await tester.tap(find.byKey(const Key('detail-gallery-previous')));
    await tester.pumpAndSettle();

    expect(find.text('item2.png'), findsOneWidget);
    expect(find.text('prompt 2'), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.byKey(const Key('detail-gallery-previous')), findsNothing);
  });

  testWidgets('leaving the gallery reveals the last viewed result card', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.settings.generationPageColumnCount = 1;
    payloadConfig.settings.resultDisplayMode = 'classic';
    final commandStatus = GetIt.I<CommandStatus>();
    for (var index = 0; index < 8; index++) {
      final content = InfoCardContent(
        title: 'item$index.png',
        info: 'prompt $index',
        additionalInfo: {'seed': index},
        imageBytes: solidPng(64, 96),
      );
      commandStatus.commandList.add(
        Command.createAsyncNoParam(
          () async => content,
          initialValue: content,
        ),
      );
    }
    final viewmodel = GenerationPageViewmodel();
    addTearDown(viewmodel.dispose);

    await tester.pumpWidget(
      localizedApp(GenerationPageView(viewmodel: viewmodel)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('item7.png'));
    await tester.pumpAndSettle();
    for (var step = 0; step < 6; step++) {
      await tester.tap(find.byKey(const Key('detail-gallery-next')));
      await tester.pumpAndSettle();
    }
    expect(find.text('item1.png'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('detail-gallery-position')), findsNothing);
    expect(find.text('item1.png'), findsOneWidget,
        reason: 'the grid scrolls back to the result last viewed in detail');
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
    await tester.pumpAndSettle();

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
