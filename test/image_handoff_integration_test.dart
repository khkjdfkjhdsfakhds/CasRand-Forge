import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';
import 'package:nai_casrand/ui/enhance_page/view_models/enhance_page_viewmodel.dart';
import 'package:nai_casrand/ui/enhance_page/widgets/enhance_page_view.dart';
import 'package:nai_casrand/ui/director_page/view_models/director_page_viewmodel.dart';
import 'package:nai_casrand/ui/director_page/widgets/director_page_view.dart';
import 'package:nai_casrand/ui/i2i_page/view_models/i2i_page_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/i2i_page_view.dart';
import 'package:nai_casrand/ui/navigation/widgets/application_navigation_shell.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}

Uint8List _solidPng(int width, int height) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(80, 120, 200));
  return Uint8List.fromList(img.encodePng(image));
}

PayloadConfig _payload() => PayloadConfig(
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
    GetIt.I.registerSingleton(CommandStatus());
    GetIt.I.registerSingleton(NavigationRequest());
    GetIt.I.registerSingleton(_payload());
    GetIt.I.registerSingleton(GenerationPageViewmodel());
  });

  tearDown(() async {
    await GetIt.I.reset();
  });

  Widget app(
    InfoCardContent content, {
    InpaintImagePreparer? inpaintImagePreparer,
  }) {
    final navigation = GetIt.I<NavigationRequest>();
    final configuration = NavigationConfiguration.fromJson({});
    return EasyLocalization(
      key: UniqueKey(),
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
          home: ApplicationNavigationShell(
            configuration: configuration,
            navigationRequest: navigation,
            pages: {
              AppDestination.generation: Builder(
                builder: (context) => Center(
                  child: FilledButton(
                    key: const Key('open-detail'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => InfoDetailPage(content: content),
                      ),
                    ),
                    child: const Text('Open detail'),
                  ),
                ),
              ),
              AppDestination.config: const SizedBox(),
              AppDestination.imageToImage: I2iPageView(
                viewmodel: I2iPageViewmodel(),
                inpaintImagePreparer: inpaintImagePreparer,
              ),
              AppDestination.vibeReference: const SizedBox(),
              AppDestination.enhance: EnhancePageView(
                viewmodel: EnhancePageViewmodel(),
              ),
              AppDestination.directorTools: DirectorPageView(
                viewmodel: DirectorPageViewmodel(),
              ),
              AppDestination.settings: const SizedBox(),
            },
          ),
        ),
      ),
    );
  }

  testWidgets(
    'use as base shows the target frame before delayed image preparation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prepared = Completer<ImageDimensions>();
      final previewBytes = _solidPng(32, 48);
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) => prepared.future,
        createPreview: (_, __) async => previewBytes,
      );
      GetIt.I.registerSingleton(coordinator);
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('result-action-base-image')),
      );
      await tester.tap(find.byKey(const Key('result-action-base-image')));
      await tester.pump();

      expect(find.byKey(const Key('i2i-page-frame')), findsOneWidget);
      expect(
        find.byKey(const Key('image-handoff-loading-imageToImage')),
        findsOneWidget,
      );
      expect(GetIt.I<PayloadConfig>().i2iConfig.hasImage, isFalse);

      prepared.complete(const ImageDimensions(width: 64, height: 96));
      await tester.pumpAndSettle();

      expect(GetIt.I<PayloadConfig>().i2iConfig.imageBytes, same(bytes));
      expect(
        GetIt.I<PayloadConfig>().i2iConfig.previewImageBytes,
        same(previewBytes),
      );
      expect(
        find.byKey(const Key('image-handoff-loading-imageToImage')),
        findsNothing,
      );
      expect(find.byKey(const Key('i2i-image-preview-stack')), findsOneWidget);
    },
  );

  testWidgets(
    'use as base preserves the previous image after failure and retries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var attempts = 0;
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) async {
          attempts++;
          if (attempts == 1) throw const FormatException('broken image');
          return const ImageDimensions(width: 64, height: 96);
        },
      );
      GetIt.I.registerSingleton(coordinator);
      final previous = _solidPng(32, 48);
      GetIt.I<PayloadConfig>().i2iConfig.setImage(previous);
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('result-action-base-image')),
      );
      await tester.tap(find.byKey(const Key('result-action-base-image')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('image-handoff-error-imageToImage')),
        findsOneWidget,
      );
      expect(GetIt.I<PayloadConfig>().i2iConfig.imageBytes, same(previous));

      await tester.tap(
        find.byKey(const Key('image-handoff-retry-imageToImage')),
      );
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(GetIt.I<PayloadConfig>().i2iConfig.imageBytes, same(bytes));
      expect(
        find.byKey(const Key('image-handoff-error-imageToImage')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'duplicate use as base clicks produce one image preparation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prepared = Completer<ImageDimensions>();
      var preparations = 0;
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) {
          preparations++;
          return prepared.future;
        },
      );
      GetIt.I.registerSingleton(coordinator);
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('result-action-base-image')),
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('result-action-base-image')),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();

      expect(preparations, 1);
      prepared.complete(const ImageDimensions(width: 64, height: 96));
      await tester.pumpAndSettle();
      expect(GetIt.I<PayloadConfig>().i2iConfig.imageBytes, same(bytes));
    },
  );

  testWidgets(
    'enhance shows its frame before importing the image and fixed profile',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prepared = Completer<ImageDimensions>();
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) => prepared.future,
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      payload.randomProfile.paramConfig
        ..steps = 17
        ..seed = 42;
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {
          'input': 'fixed prompt',
          'negative_prompt': 'fixed negative',
          'seed': 4242,
          'steps': 36,
          'scale': 6.5,
          'model': 'nai-diffusion-4-5-curated',
        },
        imageBytes: bytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('result-action-enhance')),
      );
      await tester.tap(find.byKey(const Key('result-action-enhance')));
      await tester.pump();

      expect(find.byKey(const Key('enhance-page-frame')), findsOneWidget);
      expect(
        find.byKey(const Key('image-handoff-loading-enhance')),
        findsOneWidget,
      );
      expect(payload.enhanceConfig.hasImage, isFalse);
      expect(payload.useOverridePrompt, isFalse);

      prepared.complete(const ImageDimensions(width: 64, height: 96));
      await tester.pumpAndSettle();

      expect(payload.enhanceConfig.imageBytes, same(bytes));
      expect(payload.overridePrompt, 'fixed prompt');
      expect(payload.paramConfig.seed, 4242);
      expect(payload.paramConfig.steps, 36);
      expect(payload.randomProfile.paramConfig.seed, 42);
      expect(payload.randomProfile.paramConfig.steps, 17);
      expect(
        find.byKey(const Key('image-handoff-loading-enhance')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'director shows its frame before replacing only its source image',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prepared = Completer<ImageDimensions>();
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) => prepared.future,
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      final originalDirectorBytes = _solidPng(32, 48);
      payload.directorToolConfig.setImage(originalDirectorBytes);
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('result-action-director')),
      );
      await tester.tap(find.byKey(const Key('result-action-director')));
      await tester.pump();

      expect(find.byKey(const Key('directorTools-page-frame')), findsOneWidget);
      expect(
        find.byKey(const Key('image-handoff-loading-directorTools')),
        findsOneWidget,
      );
      expect(
          payload.directorToolConfig.imageBytes, same(originalDirectorBytes));
      expect(payload.i2iConfig.hasImage, isFalse);

      prepared.complete(const ImageDimensions(width: 64, height: 96));
      await tester.pumpAndSettle();

      expect(payload.directorToolConfig.imageBytes, same(bytes));
      expect(payload.directorToolConfig.width, 64);
      expect(payload.directorToolConfig.height, 96);
      expect(payload.i2iConfig.hasImage, isFalse);
      expect(
        find.byKey(const Key('image-handoff-loading-directorTools')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'inpaint opens the editor only after the new base image is committed',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final prepared = Completer<ImageDimensions>();
      final previewBytes = _solidPng(32, 48);
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) => prepared.future,
        createPreview: (_, __) async => previewBytes,
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      final oldBytes = _solidPng(32, 48);
      payload.i2iConfig.setImage(oldBytes);
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(
        app(
          content,
          inpaintImagePreparer: (_, __) async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const Key('result-action-inpaint')));
      await tester.tap(find.byKey(const Key('result-action-inpaint')));
      await tester.pump();

      expect(find.byKey(const Key('i2i-page-frame')), findsOneWidget);
      expect(
        find.byKey(const Key('image-handoff-loading-inpaint')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mask-editor-canvas')), findsNothing);
      expect(payload.i2iConfig.imageBytes, same(oldBytes));

      prepared.complete(const ImageDimensions(width: 64, height: 96));
      await tester.pumpAndSettle();

      expect(payload.i2iConfig.imageBytes, same(bytes));
      expect(payload.i2iConfig.previewImageBytes, same(previewBytes));
      expect(payload.i2iConfig.width, 64);
      expect(payload.i2iConfig.height, 96);
      expect(find.byKey(const Key('mask-editor-canvas')), findsOneWidget);
    },
  );

  testWidgets(
    'inpaint keeps the target frame visible while the new image is warmed',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dimensionsReady = Completer<ImageDimensions>();
      final imageReady = Completer<void>();
      final bytes = _solidPng(1536, 1536);
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) => dimensionsReady.future,
        createPreview: (_, __) async => bytes,
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      var prepareCalls = 0;
      final content = InfoCardContent(
        title: 'large-generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(
        app(
          content,
          inpaintImagePreparer: (context, candidate) {
            prepareCalls++;
            expect(candidate, same(bytes));
            return imageReady.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const Key('result-action-inpaint')));
      await tester.tap(find.byKey(const Key('result-action-inpaint')));
      await tester.pump();

      expect(find.byKey(const Key('i2i-page-frame')), findsOneWidget);
      expect(
        find.byKey(const Key('image-handoff-loading-inpaint')),
        findsOneWidget,
      );

      dimensionsReady.complete(
        const ImageDimensions(width: 1536, height: 1536),
      );
      await tester.pump();
      await tester.pump();

      expect(prepareCalls, 1);
      expect(payload.i2iConfig.imageBytes, same(bytes));
      expect(find.byKey(const Key('i2i-page-frame')), findsOneWidget);
      expect(find.byKey(const Key('mask-editor-canvas')), findsNothing);

      imageReady.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mask-editor-canvas')), findsOneWidget);
    },
  );

  testWidgets(
    'a stale image warmup cannot open an editor for an older inpaint request',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final dimensionsReady = Completer<ImageDimensions>();
      final firstImageReady = Completer<void>();
      final secondImageReady = Completer<void>();
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) => dimensionsReady.future,
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      final navigation = GetIt.I<NavigationRequest>();
      final firstBytes = _solidPng(64, 96);
      final secondBytes = _solidPng(96, 64);
      final content = InfoCardContent(
        title: 'first-generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: firstBytes,
      );

      await tester.pumpWidget(
        app(
          content,
          inpaintImagePreparer: (context, candidate) {
            if (identical(candidate, firstBytes)) {
              return firstImageReady.future;
            }
            expect(candidate, same(secondBytes));
            return secondImageReady.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const Key('result-action-inpaint')));
      await tester.tap(find.byKey(const Key('result-action-inpaint')));
      await tester.pump();

      dimensionsReady.complete(
        const ImageDimensions(width: 64, height: 96),
      );
      await tester.pump();
      await tester.pump();

      payload.i2iConfig.setPreparedImage(
        secondBytes,
        width: 96,
        height: 64,
      );
      navigation.goToI2i(I2iEntryMode.inpaint);
      await tester.pump();
      await tester.pump();

      firstImageReady.complete();
      await tester.pumpAndSettle();

      expect(payload.i2iConfig.imageBytes, same(secondBytes));
      expect(find.byKey(const Key('mask-editor-canvas')), findsNothing);

      secondImageReady.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mask-editor-canvas')), findsOneWidget);
    },
  );

  testWidgets(
    'a slower old handoff cannot overwrite the latest target or image',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final oldPrepared = Completer<ImageDimensions>();
      final latestPrepared = Completer<ImageDimensions>();
      final oldBytes = _solidPng(32, 48);
      final latestBytes = _solidPng(64, 96);
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (bytes) => identical(bytes, oldBytes)
            ? oldPrepared.future
            : latestPrepared.future,
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      final originalI2iBytes = _solidPng(16, 24);
      payload.i2iConfig.setImage(originalI2iBytes);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: oldBytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();

      expect(coordinator.useAsBaseImage(oldBytes), isTrue);
      await tester.pump();
      expect(find.byKey(const Key('i2i-page-frame')), findsOneWidget);

      expect(coordinator.sendToDirectorTools(latestBytes), isTrue);
      await tester.pump();
      expect(find.byKey(const Key('directorTools-page-frame')), findsOneWidget);

      latestPrepared.complete(const ImageDimensions(width: 64, height: 96));
      await tester.pumpAndSettle();
      expect(payload.directorToolConfig.imageBytes, same(latestBytes));
      expect(payload.i2iConfig.imageBytes, same(originalI2iBytes));

      oldPrepared.complete(const ImageDimensions(width: 32, height: 48));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('directorTools-page-frame')), findsOneWidget);
      expect(payload.directorToolConfig.imageBytes, same(latestBytes));
      expect(payload.i2iConfig.imageBytes, same(originalI2iBytes));
    },
  );

  testWidgets(
    'director failure preserves its source and retry commits the new image',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var attempts = 0;
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) async {
          attempts++;
          if (attempts == 1) throw const FormatException('invalid image');
          return const ImageDimensions(width: 64, height: 96);
        },
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      final oldBytes = _solidPng(32, 48);
      payload.directorToolConfig.setImage(oldBytes);
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('result-action-director')),
      );
      await tester.tap(find.byKey(const Key('result-action-director')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('image-handoff-error-directorTools')),
        findsOneWidget,
      );
      expect(payload.directorToolConfig.imageBytes, same(oldBytes));

      await tester.tap(
        find.byKey(const Key('image-handoff-retry-directorTools')),
      );
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(payload.directorToolConfig.imageBytes, same(bytes));
      expect(
        find.byKey(const Key('image-handoff-error-directorTools')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'enhance failure preserves image and fixed profile before retry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var attempts = 0;
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) async {
          attempts++;
          if (attempts == 1) throw const FormatException('invalid image');
          return const ImageDimensions(width: 64, height: 96);
        },
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      final oldBytes = _solidPng(32, 48);
      payload.enhanceConfig.setImage(oldBytes);
      payload
        ..useOverridePrompt = true
        ..overridePrompt = 'old fixed prompt';
      payload.paramConfig
        ..seed = 111
        ..steps = 22;
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {
          'input': 'new fixed prompt',
          'seed': 4242,
          'steps': 36,
          'model': 'nai-diffusion-4-5-curated',
        },
        imageBytes: bytes,
      );

      await tester.pumpWidget(app(content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const Key('result-action-enhance')));
      await tester.tap(find.byKey(const Key('result-action-enhance')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('image-handoff-error-enhance')),
        findsOneWidget,
      );
      expect(payload.enhanceConfig.imageBytes, same(oldBytes));
      expect(payload.overridePrompt, 'old fixed prompt');
      expect(payload.paramConfig.seed, 111);
      expect(payload.paramConfig.steps, 22);

      await tester.tap(find.byKey(const Key('image-handoff-retry-enhance')));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(payload.enhanceConfig.imageBytes, same(bytes));
      expect(payload.overridePrompt, 'new fixed prompt');
      expect(payload.paramConfig.seed, 4242);
      expect(payload.paramConfig.steps, 36);
      expect(
        find.byKey(const Key('image-handoff-error-enhance')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'inpaint failure preserves the old base and retry opens the new editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var attempts = 0;
      final coordinator = ImageHandoffCoordinator(
        payloadConfig: GetIt.I<PayloadConfig>(),
        navigation: GetIt.I<NavigationRequest>(),
        readDimensions: (_) async {
          attempts++;
          if (attempts == 1) throw const FormatException('invalid image');
          return const ImageDimensions(width: 64, height: 96);
        },
      );
      GetIt.I.registerSingleton(coordinator);
      final payload = GetIt.I<PayloadConfig>();
      final oldBytes = _solidPng(32, 48);
      payload.i2iConfig.setImage(oldBytes);
      final bytes = _solidPng(64, 96);
      final content = InfoCardContent(
        title: 'generated.png',
        info: 'prompt',
        additionalInfo: const {'seed': 4242},
        imageBytes: bytes,
      );

      await tester.pumpWidget(
        app(
          content,
          inpaintImagePreparer: (_, __) async {},
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-detail')));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const Key('result-action-inpaint')));
      await tester.tap(find.byKey(const Key('result-action-inpaint')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('image-handoff-error-inpaint')),
        findsOneWidget,
      );
      expect(payload.i2iConfig.imageBytes, same(oldBytes));
      expect(find.byKey(const Key('mask-editor-canvas')), findsNothing);

      await tester.tap(find.byKey(const Key('image-handoff-retry-inpaint')));
      await tester.pumpAndSettle();

      expect(attempts, 2);
      expect(payload.i2iConfig.imageBytes, same(bytes));
      expect(find.byKey(const Key('mask-editor-canvas')), findsOneWidget);
      expect(
        find.byKey(const Key('image-handoff-error-inpaint')),
        findsNothing,
      );
    },
  );
}
