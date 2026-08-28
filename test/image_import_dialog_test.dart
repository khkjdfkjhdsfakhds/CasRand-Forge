import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/navigation/view_models/metadata_drop_area_viewmodel.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_dialog.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}

Uint8List _testPng() {
  final image = img.Image(width: 2, height: 3);
  image.setPixelRgba(0, 0, 10, 20, 30, 255);
  return Uint8List.fromList(img.encodePng(image));
}

PayloadConfig _payloadForModel(String model) {
  return PayloadConfig(
    rootPromptConfig: PromptConfig(strs: ['random'], prompts: []),
    negativePromptConfig: PromptConfig(strs: ['random negative'], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(model: model),
    settings: Settings.fromJson({}),
    overridePrompt: 'fixed',
    useOverridePrompt: false,
    useCharacterPromptWithOverride: false,
  );
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
    translations = json.decode(
      await rootBundle.loadString('assets/l10n/en.json'),
    ) as Map<String, dynamic>;
  });

  test('image candidate reads NovelAI V5 metadata without blocking image use',
      () async {
    final bytes = _testPng();
    final candidate = await ImageImportCandidate.fromImageBytes(
      bytes: bytes,
      fileName: 'v5.png',
      extractMetadata: (_) async => json.encode({
        'Source': 'NovelAI Diffusion V5 0ADF9AB7',
        'Description': 'v5 prompt',
        'Comment': json.encode({'steps': 28, 'seed': 42}),
      }),
    );

    expect(candidate.metadata, {'steps': 28, 'seed': 42});
    expect(candidate.prompt, 'v5 prompt');
    expect(candidate.model, 'nai-diffusion-5-full');
    expect(candidate.metadataError, isNull);
  });

  test('image candidate keeps usable metadata when one field is malformed',
      () async {
    final candidate = await ImageImportCandidate.fromImageBytes(
      bytes: _testPng(),
      fileName: 'malformed.png',
      extractMetadata: (_) async => json.encode({
        'Description': 'usable prompt',
        'Comment': json.encode({'steps': 'invalid', 'seed': 42}),
      }),
    );

    expect(candidate.metadata, {'steps': 'invalid', 'seed': 42});
    expect(candidate.prompt, 'usable prompt');
    expect(candidate.metadataError, isA<FormatException>());
  });

  test('V3 chooser action uses the legacy Vibe resource list', () async {
    final payload = _payloadForModel('nai-diffusion-3');
    final navigation = NavigationRequest();
    final viewmodel = MetadataDropAreaViewmodel(
      payloadConfig: payload,
      navigation: navigation,
    );

    final accepted = await viewmodel.useAsVibeTransfer(
      _testPng(),
      'legacy-vibe.png',
    );

    expect(accepted, isTrue);
    expect(payload.vibeConfigList, hasLength(1));
    expect(payload.vibeConfigListV4, isEmpty);
    expect(navigation.requestedDestination.value, AppDestination.vibeReference);
  });

  testWidgets('NAI5 chooser offers Image2Image and imports an ordinary image', (
    tester,
  ) async {
    final payload = _payloadForModel('nai-diffusion-5-full');
    final navigation = NavigationRequest();
    final handoff = ImageHandoffCoordinator(
      payloadConfig: payload,
      navigation: navigation,
      readDimensions: (_) async => const ImageDimensions(width: 2, height: 3),
      createPreview: (bytes, _) async => bytes,
    );
    final viewmodel = MetadataDropAreaViewmodel(
      payloadConfig: payload,
      imageHandoff: handoff,
    );
    final bytes = _testPng();

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: bytes,
                      fileName: 'ordinary.png',
                    ),
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('image-import-preview')), findsOneWidget);
    expect(find.byKey(const Key('image-import-i2i')), findsOneWidget);
    expect(find.byKey(const Key('image-import-inpaint')), findsOneWidget);
    expect(find.byKey(const Key('image-import-vibe')), findsNothing);
    expect(
        find.byKey(const Key('image-import-precise-reference')), findsNothing);
    expect(
        find.byKey(const Key('image-import-metadata-section')), findsNothing);

    await tester.tap(find.byKey(const Key('image-import-i2i')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(navigation.requestedDestination.value, AppDestination.imageToImage);
    expect(payload.i2iConfig.imageBytes, bytes);
    expect(payload.promptMode, PromptMode.random);
  });

  testWidgets('NAI5 inpaint action opens the mask-editor entry mode', (
    tester,
  ) async {
    final payload = _payloadForModel('nai-diffusion-5-full');
    final navigation = NavigationRequest();
    final handoff = ImageHandoffCoordinator(
      payloadConfig: payload,
      navigation: navigation,
      readDimensions: (_) async => const ImageDimensions(width: 2, height: 3),
      createPreview: (bytes, _) async => bytes,
    );
    final viewmodel = MetadataDropAreaViewmodel(
      payloadConfig: payload,
      imageHandoff: handoff,
    );
    final bytes = _testPng();

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: bytes,
                      fileName: 'inpaint.png',
                    ),
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open Inpaint'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Inpaint'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('image-import-inpaint')));
    await tester.pumpAndSettle();

    expect(payload.i2iConfig.imageBytes, same(bytes));
    expect(navigation.requestedDestination.value, AppDestination.imageToImage);
    expect(navigation.i2iEntryMode, I2iEntryMode.inpaint);
    expect(payload.promptMode, PromptMode.random);
  });

  testWidgets('V4.5 chooser imports an image as a Vibe reference', (
    tester,
  ) async {
    final payload = _payloadForModel('nai-diffusion-4-5-full');
    final navigation = NavigationRequest();
    final viewmodel = MetadataDropAreaViewmodel(
      payloadConfig: payload,
      navigation: navigation,
    );
    final bytes = _testPng();

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: bytes,
                      fileName: 'vibe.png',
                    ),
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open Vibe'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Vibe'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('image-import-vibe')), findsOneWidget);
    expect(
      find.byKey(const Key('image-import-precise-reference')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('image-import-vibe')));
    await tester.pumpAndSettle();

    expect(payload.vibeConfigListV4, hasLength(1));
    expect(payload.vibeConfigListV4.single.imageBytes, same(bytes));
    expect(navigation.requestedDestination.value, AppDestination.vibeReference);
    expect(payload.promptMode, PromptMode.random);
  });

  testWidgets('V4.5 chooser imports an image as a Precise Reference', (
    tester,
  ) async {
    final payload = _payloadForModel('nai-diffusion-4-5-full');
    final navigation = NavigationRequest();
    final viewmodel = MetadataDropAreaViewmodel(
      payloadConfig: payload,
      navigation: navigation,
      preciseReferenceImporter: (bytes, fileName) async {
        payload.preciseReferenceConfigList.add(
          PreciseReferenceConfig(
            imageB64: base64Encode(bytes),
            fileName: fileName,
          ),
        );
        return true;
      },
    );
    final bytes = _testPng();

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: bytes,
                      fileName: 'reference.png',
                    ),
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open Reference'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Reference'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('image-import-precise-reference')),
    );
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() async {
      while (payload.preciseReferenceConfigList.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(payload.preciseReferenceConfigList, hasLength(1));
    expect(payload.preciseReferenceConfigList.single.fileName, 'reference.png');
    expect(payload.preciseReferenceConfigList.single.imageBytes, isNotEmpty);
    expect(navigation.requestedDestination.value, AppDestination.vibeReference);
    expect(payload.promptMode, PromptMode.random);
  });

  testWidgets('metadata choices import only selected fixed-profile categories',
      (
    tester,
  ) async {
    final payload = _payloadForModel('nai-diffusion-5-full');
    payload.fixedProfile.negativePromptConfig =
        PayloadConfig.fixedPromptConfig('keep negative', negative: true);
    payload.fixedProfile.paramConfig
      ..negativePrompt = 'keep negative'
      ..steps = 12
      ..randomSeed = false
      ..seed = 111;
    final viewmodel = MetadataDropAreaViewmodel(payloadConfig: payload);
    final bytes = _testPng();

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: bytes,
                      fileName: 'metadata.png',
                      prompt: 'imported positive',
                      model: 'nai-diffusion-4-5-full',
                      metadata: const {
                        'uc': 'imported negative',
                        'steps': 30,
                        'seed': 999,
                        'width': 1024,
                        'height': 1024,
                      },
                    ),
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open Metadata'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Metadata'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('image-import-metadata-section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('image-import-fixed-mode-warning')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('metadata-import-prompt')), findsOneWidget);
    expect(find.byKey(const Key('metadata-import-characters')), findsNothing);
    expect(find.byKey(const Key('metadata-import-append')), findsOneWidget);
    expect(find.byKey(const Key('metadata-import-clean')), findsOneWidget);

    final undesired = find.byKey(const Key('metadata-import-undesired'));
    await tester.ensureVisible(undesired);
    await tester.tap(undesired);
    final seed = find.byKey(const Key('metadata-import-seed'));
    await tester.ensureVisible(seed);
    await tester.tap(seed);
    final confirm = find.byKey(const Key('metadata-import-confirm'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(payload.promptMode, PromptMode.fixed);
    expect(payload.fixedProfile.rootPromptConfig.strs, ['imported positive']);
    expect(payload.fixedProfile.negativePromptConfig.strs, ['keep negative']);
    expect(payload.fixedProfile.paramConfig.steps, 30);
    expect(payload.fixedProfile.paramConfig.model, 'nai-diffusion-4-5-full');
    expect(payload.fixedProfile.paramConfig.seed, 111);
  });

  testWidgets('chooser remains scrollable on a narrow phone surface', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final payload = _payloadForModel('nai-diffusion-4-5-full');
    final viewmodel = MetadataDropAreaViewmodel(payloadConfig: payload);

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: _testPng(),
                      fileName: 'narrow.png',
                      prompt: 'prompt',
                      metadata: const {
                        'uc': 'negative',
                        'steps': 28,
                        'seed': 42,
                      },
                    ),
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open Narrow'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Narrow'));
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    final confirm = find.byKey(const Key('metadata-import-confirm'));
    await tester.ensureVisible(confirm);
    expect(confirm, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'chooser paints immediately while metadata loads and tolerates malformed fields',
      (tester) async {
    final payload = _payloadForModel('nai-diffusion-5-full');
    final viewmodel = MetadataDropAreaViewmodel(payloadConfig: payload);
    final metadata = Completer<ImageImportCandidate>();
    final bytes = _testPng();

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: bytes,
                      fileName: 'malformed.png',
                    ),
                    metadataLoader: () => metadata.future,
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open Deferred'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Deferred'));
    await tester.pump();

    expect(find.byKey(const Key('image-import-preview')), findsOneWidget);
    expect(
        find.byKey(const Key('image-import-metadata-loading')), findsOneWidget);
    expect(find.byKey(const Key('image-import-i2i')), findsOneWidget);

    metadata.complete(
      ImageImportCandidate(
        bytes: bytes,
        fileName: 'malformed.png',
        metadata: const {'steps': 'not-a-number', 'seed': <String>[]},
        metadataError:
            const FormatException('Some metadata fields are invalid.'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
        find.byKey(const Key('image-import-metadata-loading')), findsNothing);
    expect(find.byKey(const Key('image-import-i2i')), findsOneWidget);
    expect(
      find.text(translations['image_import_metadata_invalid'] as String),
      findsOneWidget,
    );
    expect(
        find.textContaining('Some metadata fields are invalid.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed actions stay open and repeated taps submit only once',
      (tester) async {
    final payload = _payloadForModel('nai-diffusion-4-5-full');
    final navigation = NavigationRequest()..goTo(AppDestination.directorTools);
    final gate = Completer<void>();
    var attempts = 0;
    final viewmodel = MetadataDropAreaViewmodel(
      payloadConfig: payload,
      navigation: navigation,
      preciseReferenceImporter: (bytes, fileName) async {
        attempts++;
        await gate.future;
        throw const FormatException('bad image');
      },
    );

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
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showImageImportDialog(
                    context,
                    candidate: ImageImportCandidate(
                      bytes: _testPng(),
                      fileName: 'bad.png',
                    ),
                    viewmodel: viewmodel,
                  ),
                  child: const Text('Open Failure'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Failure'));
    await tester.pumpAndSettle();

    final action = find.byKey(const Key('image-import-precise-reference'));
    await tester.tap(action);
    await tester.tap(action, warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const Key('image-import-action-loading')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(ImageImportDialog), findsOneWidget);
    expect(
      navigation.requestedDestination.value,
      AppDestination.directorTools,
    );

    gate.complete();
    await tester.pumpAndSettle();

    expect(attempts, 1);
    expect(find.byType(ImageImportDialog), findsOneWidget);
    expect(find.text(translations['image_import_action_failed'] as String),
        findsOneWidget);
    expect(find.textContaining('bad image'), findsNothing);
    expect(
      navigation.requestedDestination.value,
      AppDestination.directorTools,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ImageImportDialog), findsNothing);
  });

  test('image import copy exists in both bundled locales', () async {
    final zh = json.decode(
      await rootBundle.loadString('assets/l10n/zh-CN.json'),
    ) as Map<String, dynamic>;
    for (final key in const [
      'image_import_title',
      'image_import_fixed_mode_warning',
      'image_import_metadata_confirm',
    ]) {
      expect(translations[key], isA<String>());
      expect(zh[key], isA<String>());
      expect((zh[key] as String).trim(), isNotEmpty);
    }
  });
}
