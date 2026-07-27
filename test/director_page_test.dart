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
import 'package:nai_casrand/ui/director_page/view_models/director_page_viewmodel.dart';
import 'package:nai_casrand/ui/director_page/widgets/director_page_view.dart';
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
      'seed': 4242,
      'width': 832,
      'height': 1216,
      'steps': 28,
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
        negativePromptConfig: PromptConfig(strs: [], prompts: []),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
        ),
        settings: Settings.fromJson({}),
        overridePrompt: '',
        useOverridePrompt: false,
        useCharacterPromptWithOverride: false,
      ),
    );
    GetIt.instance.registerSingleton(GenerationPageViewmodel());
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

  testWidgets('without a source workspace and controls stay visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      localizedApp(DirectorPageView(viewmodel: DirectorPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('director-import-image-area')), findsOneWidget);
    expect(find.byKey(const Key('transform-original-stage')), findsOneWidget);
    expect(find.byKey(const Key('transform-result-stage')), findsOneWidget);
    expect(find.byKey(const Key('director-tool-bg-removal')), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('director-tool-bg-removal')),
          )
          .onSelected,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('director-run')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a source reveals all seven tools with their prices', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GetIt.I<PayloadConfig>().directorToolConfig.setImage(solidPng(512, 512));

    await tester.pumpWidget(
      localizedApp(DirectorPageView(viewmodel: DirectorPageViewmodel())),
    );
    await tester.pumpAndSettle();

    for (final tool in [
      'bg-removal',
      'lineart',
      'sketch',
      'colorize',
      'emotion',
      'declutter',
      'declutter-keep-bubbles',
    ]) {
      expect(find.byKey(Key('director-tool-$tool')), findsOneWidget,
          reason: tool);
    }
    // Measured prices at 512x512: bg-removal 20, everything else 5.
    expect(find.text('Remove BG · 20'), findsOneWidget);
    expect(find.text('Line Art · 5'), findsOneWidget);
    expect(find.text('Declutter (keep bubbles) · 5'), findsOneWidget);
  });

  testWidgets('the run button and notice state the cost', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GetIt.I<PayloadConfig>().directorToolConfig.setImage(solidPng(512, 512));

    await tester.pumpWidget(
      localizedApp(DirectorPageView(viewmodel: DirectorPageViewmodel())),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Run tool · 20'), findsOneWidget);
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip).first).message,
      contains('20'),
    );
  });

  testWidgets('picking a cheaper tool updates the quoted cost', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().directorToolConfig;
    config.setImage(solidPng(512, 512));

    await tester.pumpWidget(
      localizedApp(DirectorPageView(viewmodel: DirectorPageViewmodel())),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Run tool · 20'), findsOneWidget);

    final lineart = find.byKey(const Key('director-tool-lineart'));
    await tester.ensureVisible(lineart);
    await tester.tap(lineart);
    await tester.pumpAndSettle();

    expect(config.type, 'lineart');
    expect(find.textContaining('Run tool · 5'), findsOneWidget);
  });

  testWidgets('emotion exposes its emotion picker and defry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final config = GetIt.I<PayloadConfig>().directorToolConfig;
    config.setImage(solidPng(512, 512));

    await tester.pumpWidget(
      localizedApp(DirectorPageView(viewmodel: DirectorPageViewmodel())),
    );
    await tester.pumpAndSettle();

    // Non-prompt tools hide the prompt controls.
    expect(find.byKey(const Key('director-defry')), findsNothing);

    final emotion = find.byKey(const Key('director-tool-emotion'));
    await tester.ensureVisible(emotion);
    await tester.tap(emotion);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('director-emotion-happy')), findsOneWidget);
    expect(find.byKey(const Key('director-defry')), findsOneWidget);
    expect(find.byKey(const Key('director-override-enabled')), findsOneWidget);
  });

  testWidgets('a larger source raises the quoted cost', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GetIt.I<PayloadConfig>().directorToolConfig.setImage(solidPng(1024, 1024));

    await tester.pumpWidget(
      localizedApp(DirectorPageView(viewmodel: DirectorPageViewmodel())),
    );
    await tester.pumpAndSettle();

    // Measured at 1024x1024: bg-removal 65.
    expect(find.text('Remove BG · 65'), findsOneWidget);
    expect(find.textContaining('Run tool · 65'), findsOneWidget);
  });
}
