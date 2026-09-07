import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';

PayloadConfig configFor(String model, {String prompt = 'a sign'}) =>
    PayloadConfig(
      rootPromptConfig:
          PromptConfig(strs: [prompt], prompts: [], shuffled: false),
      negativePromptConfig: PromptConfig(strs: ['bad'], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(model: model, randomSeed: false, seed: 42),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

const infill = I2iRequestPlan(
  imageB64: 'image',
  maskB64: 'mask',
  width: 512,
  height: 512,
  strength: .6,
  noise: 0,
  addOriginalImage: false,
  composite: null,
  summary: 'test infill',
);

void main() {
  for (final mode in PromptMode.values) {
    for (final model in ['nai-diffusion-5-full', 'nai-diffusion-5-curated']) {
      test(
          '$mode $model allows 23 characters and preserves them on model switch',
          () {
        final config = configFor(model)..promptMode = mode;
        config.paramConfig.model = model;
        final vm = PromptTabViewmodel(payloadConfig: config);
        for (var i = 0; i < 24; i++) {
          vm.addCharacter();
        }
        expect(vm.characterConfigList, hasLength(23));
        expect(vm.canAddCharacter, isFalse);
        for (var i = 0; i < 23; i++) {
          vm.characterConfigList[i].positivePromptConfig =
              PayloadConfig.fixedPromptConfig('person $i');
        }
        expect(
            GeneratePayloadUseCase(payloadConfig: config)()
                .payload['parameters']['v4_prompt']['caption']['char_captions'],
            hasLength(23));
        vm.paramConfig.model = 'nai-diffusion-4-5-full';
        vm.addCharacter();
        expect(vm.characterConfigList, hasLength(23));
        expect(vm.canAddCharacter, isFalse);
        vm.characterConfigList.clear();
        for (var i = 0; i < 7; i++) {
          vm.addCharacter();
        }
        expect(vm.characterConfigList, hasLength(6));
        vm.dispose();
      });
    }
  }

  const prompts = {
    'a sign, Text: HELLO': 'a sign, transparent background, Text: HELLO',
    'Text: transparent background':
        'transparent background, Text: transparent background',
    'a sign, teXt: HELLO|second scene':
        'a sign, transparent background, teXt: HELLO|second scene',
    'scene ||red|blue||, Text: HELLO|second':
        'scene ||red|blue||, transparent background, Text: HELLO|second',
    'scene|second, transparent background':
        'scene, transparent background|second, transparent background',
    'scene, transparent background, Text: HELLO':
        'scene, transparent background, Text: HELLO',
    'a sign "HELLO"': 'a sign "HELLO", transparent background, teXt: HELLO',
  };
  for (final entry in prompts.entries) {
    test('transparent suffix preserves text and chunk boundaries: ${entry.key}',
        () {
      final config = configFor('nai-diffusion-5-full', prompt: entry.key);
      config.paramConfig.transparentBackground = true;
      final request = GeneratePayloadUseCase(payloadConfig: config)().payload;
      expect(request['input'], entry.value);
      expect(request['parameters']['v4_prompt']['caption']['base_caption'],
          entry.value);
      expect(config.rootPromptConfig.strs.single, entry.key);
    });
  }

  test(
      'Curated infill uses effective model capabilities without mutating settings',
      () {
    final config =
        configFor('nai-diffusion-5-curated', prompt: 'a sign "HELLO"');
    config.paramConfig
      ..transparentBackground = true
      ..straightAlpha = true
      ..varietyPlus = true
      ..dynamicThresholding = true;
    config.characterConfigList.add(CharacterConfig.fromEmpty()
      ..freeCenter = const Point(.244, .81)
      ..positivePromptConfig = PayloadConfig.fixedPromptConfig('person'));
    final before = config.paramConfig.toJson();
    final result =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: infill)()
            .payload;
    final parameters = result['parameters'];
    expect(result['model'], 'nai-diffusion-4-5-curated-inpainting');
    expect(result['input'], 'a sign "HELLO"');
    for (final key in [
      'straight_alpha',
      'tag_hint_qt',
      'tag_hint_uc_preset',
      'tag_hint_transparent_background'
    ]) {
      expect(parameters.containsKey(key), isFalse);
    }
    expect(parameters['noise_schedule'], 'karras');
    expect(parameters['skip_cfg_above_sigma'], isNotNull);
    expect(parameters['dynamic_thresholding'], isTrue);
    expect(parameters['v4_prompt']['caption']['char_captions'][0]['centers'], [
      {'x': .3, 'y': .9}
    ]);
    expect(config.paramConfig.toJson(), before);
    expect(
        config.characterConfigList.single.freeCenter, const Point(.244, .81));
    final tile = GeneratePayloadUseCase.applyI2iPlanToPayload(result, infill);
    expect(tile, result);
  });

  test('ordinary V5 retains manual sampling controls and full infill keeps V5',
      () {
    final config = configFor('nai-diffusion-5-full', prompt: 'a sign "HELLO"');
    config.paramConfig
      ..transparentBackground = true
      ..varietyPlus = true
      ..dynamicThresholding = true
      ..noiseSchedule = 'native';
    for (final plan in [null, infill]) {
      final request =
          GeneratePayloadUseCase(payloadConfig: config, i2iPlan: plan)()
              .payload;
      final parameters = request['parameters'];
      expect(
          request['model'],
          plan == null
              ? 'nai-diffusion-5-full'
              : 'nai-diffusion-5-full-inpainting');
      expect(request['input'],
          'a sign "HELLO", transparent background, teXt: HELLO');
      expect(parameters['noise_schedule'], 'native');
      expect(parameters['skip_cfg_above_sigma'], isNotNull);
      expect(parameters['dynamic_thresholding'], isTrue);
      expect(parameters['straight_alpha'], isTrue);
    }
  });
}
