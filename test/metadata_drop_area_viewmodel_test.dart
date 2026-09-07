import 'dart:math';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/ui/navigation/view_models/metadata_drop_area_viewmodel.dart';

class _TestAssetLoader extends AssetLoader {
  final Map<String, dynamic> translations;

  const _TestAssetLoader(this.translations);

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

void main() {
  late Map<String, dynamic> testTranslations;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    final source = await rootBundle.loadString('assets/l10n/en.json');
    testTranslations = json.decode(source) as Map<String, dynamic>;
  });

  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton(
      PayloadConfig(
        rootPromptConfig: PromptConfig(strs: [], prompts: []),
        negativePromptConfig: PromptConfig(
          selectionMethod: 'single',
          shuffled: true,
          strs: ['old negative one', 'old negative two'],
          prompts: [],
        ),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(autoPosition: false),
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

  Widget localizedApp(Widget child) {
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
          home: Scaffold(body: child),
        ),
      ),
    );
  }

  testWidgets('drop metadata import uses full payload config migration', (
    tester,
  ) async {
    final viewmodel = MetadataDropAreaViewmodel();

    await tester.pumpWidget(
      localizedApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => viewmodel.loadAllMetadata(
              context,
              {
                'seed': 45744032,
                'uc': 'metadata negative',
                'deliberate_euler_ancestral_bug': false,
                'prefer_brownian': true,
                'v4_prompt': {'use_coords': true},
              },
              'exact website prompt',
              'nai-diffusion-4-5-full',
            ),
            child: const Text('Import'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pump();

    final payloadConfig = GetIt.I<PayloadConfig>();
    expect(payloadConfig.paramConfig.randomSeed, isFalse);
    expect(payloadConfig.paramConfig.seed, 45744032);
    expect(payloadConfig.paramConfig.autoPosition, isFalse);
    expect(payloadConfig.paramConfig.deliberateEulerAncestralBug, isFalse);
    expect(payloadConfig.paramConfig.preferBrownian, isTrue);
    expect(payloadConfig.paramConfig.model, 'nai-diffusion-4-5-full');
    expect(payloadConfig.overridePrompt, 'exact website prompt');
    expect(payloadConfig.useOverridePrompt, isTrue);
    expect(payloadConfig.paramConfig.negativePrompt, 'metadata negative');
    expect(payloadConfig.negativePromptConfig.selectionMethod, 'all');
    expect(payloadConfig.negativePromptConfig.strs, ['metadata negative']);

    final generated =
        GeneratePayloadUseCase(payloadConfig: payloadConfig)().payload;
    final parameters = generated['parameters'] as Map<String, dynamic>;
    expect(generated['input'], 'exact website prompt');
    expect(parameters['seed'], 45744032);
    expect(parameters['deliberate_euler_ancestral_bug'], isFalse);
    expect(parameters['prefer_brownian'], isTrue);
    expect(parameters['v4_prompt']['use_coords'], isTrue);
  });

  test('V5 metadata import preserves the continuous free-center coordinate',
      () {
    final metadata = {
      'seed': 2416261015,
      'width': 832,
      'height': 1216,
      'model_name': 'NovelAI Diffusion V5',
      'v4_prompt': {
        'caption': {
          'base_caption': '1girl, best quality',
          'char_captions': [
            {
              'char_caption': 'girl, misaka_mikoto,',
              'centers': [
                {'x': 0.244, 'y': 0.541},
              ],
            },
          ],
        },
        'use_coords': true,
        'use_order': true,
      },
      'v4_negative_prompt': {
        'caption': {
          'base_caption': 'blur, lowres',
          'char_captions': [
            {
              'char_caption': '',
              'centers': [
                {'x': 0.244, 'y': 0.541},
              ],
            },
          ],
        },
        'use_coords': false,
      },
    };

    final payloadConfig = GetIt.I<PayloadConfig>();
    payloadConfig.importMetadataToFixedProfile(metadata);
    final characters = payloadConfig.characterConfigList;

    expect(characters, hasLength(1));
    final character = characters.first;
    expect(character.freeCenter, const Point<double>(0.244, 0.541));
    expect(character.positions, isEmpty);
    expect(character.positivePromptConfig.strs.first, 'girl, misaka_mikoto,');
  });
}
