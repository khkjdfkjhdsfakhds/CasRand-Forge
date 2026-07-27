import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
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
    GetIt.I.registerSingleton(CommandStatus());
    GetIt.I.registerSingleton(
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
    GetIt.I.registerSingleton(GenerationPageViewmodel());
  });

  tearDown(() async => GetIt.I.reset());

  Widget app() => EasyLocalization(
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
            home: DirectorPageView(viewmodel: DirectorPageViewmodel()),
          ),
        ),
      );

  testWidgets('workspace and disabled tool controls stay visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('transform-original-stage')), findsOneWidget);
    expect(find.byKey(const Key('transform-result-stage')), findsOneWidget);
    expect(
      find.byKey(const Key('director-tool-bg-removal')),
      findsOneWidget,
    );
    final run = tester.widget<FilledButton>(
      find.byKey(const Key('director-run')),
    );
    expect(run.onPressed, isNull);
  });

  testWidgets('loading an image enables the prominent run button', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 128, height: 128)),
    );
    GetIt.I<PayloadConfig>().directorToolConfig.setImage(bytes);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final run = tester.widget<FilledButton>(
      find.byKey(const Key('director-run')),
    );
    expect(run.onPressed, isNotNull);
    expect(find.textContaining('·'), findsWidgets);
  });
}
