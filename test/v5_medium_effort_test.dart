import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/data/use_cases/enhance_request_options.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';

PayloadConfig _config({
  String model = v5FullMediumModel,
  String prompt = '1girl, smile',
}) {
  return PayloadConfig(
    rootPromptConfig:
        PromptConfig(shuffled: false, strs: [prompt], prompts: []),
    negativePromptConfig: PromptConfig(
      shuffled: false,
      strs: ['custom negative'],
      prompts: [],
    ),
    characterConfigList: [
      CharacterConfig(
        positions: [CharacterConfig.defaultPosition],
        positivePromptConfig:
            PromptConfig(shuffled: false, strs: ['red hair'], prompts: []),
        negativePromptConfig:
            PromptConfig(shuffled: false, strs: ['bad hands'], prompts: []),
        gender: CharacterConfig.genderOther,
        enabled: true,
      ),
    ],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(
      model: model,
      steps: 28,
      sampler: 'k_dpmpp_2m',
      cfgRescale: 0.3,
      tagHintUcPreset: 0,
      randomSeed: false,
      seed: 5,
    ),
    settings: Settings.fromJson({}),
    overridePrompt: '',
    useOverridePrompt: false,
    useCharacterPromptWithOverride: false,
  );
}

class _Loader extends AssetLoader {
  _Loader(this.words);
  final Map<String, dynamic> words;
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => words;
}

void main() {
  test('Medium effort model ids, metadata hashes and inpaint routing', () {
    expect(isMediumEffortModel(v5FullMediumModel), isTrue);
    expect(
        isMediumEffortModel('nai-diffusion-5-full-medium-inpainting'), isTrue);
    expect(isMediumEffortModel(v5FullModel), isFalse);
    expect(models.indexOf(v5FullMediumModel), models.indexOf(v5FullModel) + 1);

    expect(modelFromSource('NovelAI Diffusion V5 93F4BD30'), v5FullMediumModel);
    expect(modelFromSource('NovelAI Diffusion V5 70AB5786'), v5FullMediumModel);
    expect(effectiveGenerationModel(v5FullMediumModel, inpaint: true),
        'nai-diffusion-5-full-medium-inpainting');
    expect(
        effectiveGenerationModel('nai-diffusion-5-full-medium-inpainting',
            inpaint: false),
        v5FullMediumModel);
    expect(EnhanceRequestOptions.supportsMax(v5FullMediumModel), isTrue);
  });

  test('Medium payload pins official settings but keeps stored High values',
      () {
    final config = _config().paramConfig;
    final payload = config.getPayload();

    expect(payload['steps'], 14);
    expect(payload['sampler'], 'k_euler_ancestral');
    expect(payload.containsKey('cfg_rescale'), isFalse);
    expect(payload['tag_hint_uc_preset'], 2);
    expect(config.steps, 28);
    expect(config.sampler, 'k_dpmpp_2m');
    expect(config.cfgRescale, 0.3);

    final high = (config..model = v5FullModel).getPayload();
    expect(high['steps'], 28);
    expect(high['sampler'], 'k_dpmpp_2m');
    expect(high['cfg_rescale'], 0.3);
    expect(high['tag_hint_uc_preset'], 0);
  });

  test('Medium replaces custom negative prompts with the Heavy preset', () {
    final result = GeneratePayloadUseCase(payloadConfig: _config())();
    final parameters = result.payload['parameters'] as Map<String, dynamic>;
    const expected = 'nsfw, $v5HeavyUcPreset';

    expect(result.payload['model'], v5FullMediumModel);
    expect(parameters['negative_prompt'], expected);
    expect(
        parameters['v4_negative_prompt']['caption']['base_caption'], expected);
    expect(parameters['characterPrompts'].single['uc'], '');
    expect(
      parameters['v4_negative_prompt']['caption']['char_captions']
          .single['char_caption'],
      '',
    );
    expect(result.comment, isNot(contains('custom negative')));
    expect(result.comment, isNot(contains('bad hands')));

    final nsfw = GeneratePayloadUseCase(
      payloadConfig: _config(prompt: '1girl, NSFW'),
    )()
        .payload['parameters'];
    expect(nsfw['negative_prompt'], v5HeavyUcPreset);

    final high =
        GeneratePayloadUseCase(payloadConfig: _config(model: v5FullModel))()
            .payload['parameters'];
    expect(high['negative_prompt'], 'custom negative');
    expect(high['characterPrompts'].single['uc'], 'bad hands');
  });

  test('Medium inpainting uses the Medium inpainting model', () {
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: 'bWFzaw==',
      width: 1024,
      height: 1024,
      strength: 1,
      noise: 0,
      addOriginalImage: false,
      composite: null,
      summary: 'medium inpaint',
    );
    final payload =
        GeneratePayloadUseCase(payloadConfig: _config(), i2iPlan: plan)()
            .payload;
    expect(payload['model'], 'nai-diffusion-5-full-medium-inpainting');
    expect(payload['parameters']['steps'], 14);
    expect(payload['parameters']['negative_prompt'], 'nsfw, $v5HeavyUcPreset');
  });

  test('Medium cost uses 14 steps and the official discount', () {
    const width = 832, height = 1216, area = width * height;
    final base = (2951823174884865e-21 * area +
            5753298233447344e-22 * area * 14 * (1 / 1.06521739))
        .ceil();
    final expected = (base * 1.5).ceil();

    final medium = estimateAnlasCost(
      width: width,
      height: height,
      steps: 28,
      model: v5FullMediumModel,
    );
    final high23 = estimateAnlasCost(
      width: width,
      height: height,
      steps: 23,
      model: v5FullModel,
    );
    expect(medium.perImageAnlas, expected);
    expect(medium.perImageAnlas, lessThan(high23.perImageAnlas));

    final opus = estimateAnlasCost(
      width: 1024,
      height: 1024,
      steps: 50,
      model: v5FullMediumModel,
      tier: opusTier,
      subscriptionActive: true,
      opusUsageAvailable: true,
    );
    expect(opus.isFreeUnderOpus, isTrue);
  });

  test('importing Medium metadata keeps High defaults underneath', () {
    final config = _config(model: v5FullModel);
    config.importMetadataToFixedProfile(
      {
        'steps': 14,
        'sampler': 'k_euler_ancestral',
        'cfg_rescale': 0.0,
        'scale': 6.0,
        'width': 832,
        'height': 1216,
        'seed': 42,
        'uc': 'nsfw, $v5HeavyUcPreset',
      },
      prompt: '1girl',
      model: v5FullMediumModel,
    );
    final imported = config.fixedProfile.paramConfig;
    expect(imported.model, v5FullMediumModel);
    expect(imported.scale, 6.0);
    expect(imported.steps, 23);
    expect(imported.sampler, 'k_euler_ancestral');
    expect(imported.getPayload()['steps'], 14);
  });

  group('Medium effort UI', () {
    late Map<String, dynamic> words;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/shared_preferences'),
              (call) async =>
                  call.method == 'getAll' ? <String, Object>{} : true);
      await EasyLocalization.ensureInitialized();
      words = jsonDecode(await rootBundle.loadString('assets/l10n/en.json'));
    });

    tearDown(() => GetIt.I.reset());

    Widget app(Widget child) => EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'unused',
          assetLoader: _Loader(words),
          saveLocale: false,
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              home: Scaffold(body: child),
            ),
          ),
        );

    testWidgets('Medium model hides pinned controls and explains them',
        (tester) async {
      final payload = _config(model: v5FullModel);
      GetIt.I.registerSingleton<PayloadConfig>(payload);
      final viewmodel = ParametersConfigViewmodel();
      await tester.pumpWidget(app(ParametersConfigView(viewmodel: viewmodel)));
      await tester.pumpAndSettle();
      final rescaleSlider = find.byWidgetPredicate((widget) =>
          widget is Text &&
          (widget.data ?? '').startsWith('Prompt Guidance Rescale'));
      final modelNotice = find
          .byKey(const Key('medium-effort-notice-medium_effort_model_notice'));

      expect(modelNotice, findsNothing);
      expect(find.byKey(const Key('sampling-steps-control')), findsOneWidget);
      expect(find.text('Sampler'), findsOneWidget);
      expect(rescaleSlider, findsOneWidget);

      viewmodel.setModel(v5FullMediumModel);
      await tester.pumpAndSettle();

      expect(payload.paramConfig.model, v5FullMediumModel);
      expect(find.text(v5FullMediumModel), findsOneWidget);
      expect(modelNotice, findsOneWidget);
      expect(find.byKey(const Key('sampling-steps-control')), findsNothing);
      expect(find.text('Sampler'), findsNothing);
      expect(rescaleSlider, findsNothing);

      viewmodel.setModel(v5FullModel);
      await tester.pumpAndSettle();
      expect(payload.paramConfig.steps, 28);
      expect(payload.paramConfig.sampler, 'k_dpmpp_2m');
      expect(find.byKey(const Key('sampling-steps-control')), findsOneWidget);
    });

    for (final mode in [PromptMode.random, PromptMode.fixed]) {
      testWidgets('negative prompt editors explain Medium effort ($mode)',
          (tester) async {
        final payload = _config()..promptMode = mode;
        GetIt.I.registerSingleton<PayloadConfig>(payload);
        Widget tab() => app(PromptTabView(
              viewmodel: PromptTabViewmodel(payloadConfig: payload),
              promptAssistance: PromptEditingAssistance.fromCandidates([]),
            ));
        await tester.pumpWidget(tab());
        await tester.pumpAndSettle();
        final notice = find.byKey(
            const Key(
                'medium-effort-notice-medium_effort_negative_prompt_notice'),
            skipOffstage: false);
        final characterNotice = find.byKey(
            const Key(
                'medium-effort-notice-medium_effort_character_negative_notice'),
            skipOffstage: false);
        expect(notice, findsOneWidget);
        // The fixed profile of this fixture has no characters.
        expect(
            characterNotice, findsNWidgets(mode == PromptMode.random ? 1 : 0));

        payload.paramConfig.model = v5FullModel;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(tab());
        await tester.pumpAndSettle();
        expect(notice, findsNothing);
        expect(characterNotice, findsNothing);
      });
    }
  });
}
