import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

class _UpperBoundRandom implements Random {
  int? requestedMax;

  @override
  bool nextBool() => true;

  @override
  double nextDouble() => 1;

  @override
  int nextInt(int max) {
    requestedMax = max;
    return max - 1;
  }
}

void main() {
  test('override prompt replaces generated root prompt when enabled', () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['generated root prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['generated negative prompt'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: 'preserved override prompt',
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
    );

    final result = GeneratePayloadUseCase(payloadConfig: config)();

    expect(result.payload['input'], 'preserved override prompt');
    expect(config.useOverridePrompt, isTrue);
    expect(config.overridePrompt, 'preserved override prompt');
    expect(config.toJson()['use_override_prompt'], isTrue);
    expect(config.toJson()['override_prompt'], 'preserved override prompt');
    expect(
      result.payload['parameters']['v4_prompt']['caption']['base_caption'],
      'preserved override prompt',
    );
    expect(result.payload['parameters']['v4_prompt']['use_coords'], isFalse);
  });

  test('fixed base and negative prompts keep line-leading hashes verbatim', () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['random prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['random negative'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '# literal fixed prompt\nblue eyes',
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
    );
    config.fixedProfile.negativePromptConfig = PayloadConfig.fixedPromptConfig(
      '# literal fixed negative\nbad hands',
      negative: true,
    );

    final result = GeneratePayloadUseCase(payloadConfig: config)();
    final parameters = result.payload['parameters'] as Map<String, dynamic>;

    expect(result.payload['input'], '# literal fixed prompt\nblue eyes');
    expect(
      parameters['negative_prompt'],
      '# literal fixed negative\nbad hands',
    );
  });

  test('imported V4 coordinates survive override prompt with no characters',
      () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['base prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['negative prompt'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: 'imported website prompt',
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
    );
    expect(
      config.loadParamJson({
        'v4_prompt': {'use_coords': true},
      }),
      1,
    );
    expect(config.paramConfig.autoPosition, isFalse);

    final parameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];

    expect(
      parameters['v4_prompt']['caption']['base_caption'],
      'imported website prompt',
    );
    expect(parameters['v4_prompt']['caption']['char_captions'], isEmpty);
    expect(parameters['v4_prompt']['use_coords'], isTrue);
  });

  test('global negative prompt rolls into regular and V4 request fields', () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['positive prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        selectionMethod: 'single_sequential',
        shuffled: false,
        strs: ['negative one', 'negative two'],
        prompts: [],
      ),
      characterConfigList: [
        CharacterConfig(
          positions: [],
          positivePromptConfig: PromptConfig(
            shuffled: false,
            strs: ['character positive'],
            prompts: [],
          ),
          negativePromptConfig: PromptConfig(
            selectionMethod: 'single_sequential',
            shuffled: false,
            comment: '负面内容',
            strs: ['character negative one', 'character negative two'],
            prompts: [],
          ),
          gender: CharacterConfig.genderOther,
          enabled: true,
        ),
      ],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(autoPosition: false),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

    final first = GeneratePayloadUseCase(payloadConfig: config)().payload;
    final second = GeneratePayloadUseCase(payloadConfig: config)().payload;
    final firstParameters = first['parameters'] as Map<String, dynamic>;
    final secondParameters = second['parameters'] as Map<String, dynamic>;

    expect(firstParameters['negative_prompt'], 'negative one');
    expect(secondParameters['negative_prompt'], 'negative two');
    expect(
      (firstParameters['v4_negative_prompt'] as Map)['caption']['base_caption'],
      'negative one',
    );
    expect(
      (secondParameters['v4_negative_prompt'] as Map)['caption']
          ['base_caption'],
      'negative two',
    );
    expect(
      (firstParameters['characterPrompts'] as List).single['uc'],
      'character negative one',
    );
    expect(
      (secondParameters['characterPrompts'] as List).single['uc'],
      'character negative two',
    );
    expect(
      ((firstParameters['v4_negative_prompt'] as Map)['caption']
              ['char_captions'] as List)
          .single['char_caption'],
      'character negative one',
    );
    expect(firstParameters['v4_prompt']['use_coords'], isTrue);
    expect(first['parameters']['characterPrompts'].single['center'], {
      'x': 0.5,
      'y': 0.5,
    });
    expect(
      GeneratePayloadUseCase(payloadConfig: config)().comment,
      contains('Character 1 at C3'),
    );

    config.paramConfig.autoPosition = true;
    final autoParameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];
    expect(autoParameters['v4_prompt']['use_coords'], isFalse);
  });

  test('global negative prompt resolves saved config variables', () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['positive prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['__avoid__'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [
        PromptConfig(
          shuffled: false,
          comment: 'avoid',
          strs: ['bad hands'],
          prompts: [],
        ),
      ],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

    final result = GeneratePayloadUseCase(payloadConfig: config)();

    expect(result.payload['parameters']['negative_prompt'], 'bad hands');
    expect(result.comment, contains('bad hands'));
  });

  test('character positive and negative prompts resolve saved variables', () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['base'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['global negative'],
        prompts: [],
      ),
      characterConfigList: [
        CharacterConfig(
          positions: [CharacterConfig.defaultPosition],
          positivePromptConfig: PromptConfig(
            shuffled: false,
            strs: ['__character_positive__'],
            prompts: [],
          ),
          negativePromptConfig: PromptConfig(
            shuffled: false,
            strs: ['__character_negative__'],
            prompts: [],
          ),
          gender: CharacterConfig.genderOther,
          enabled: true,
        ),
      ],
      savedPromptConfigList: [
        PromptConfig(
          shuffled: false,
          comment: 'character_positive',
          strs: ['red hair'],
          prompts: [],
        ),
        PromptConfig(
          shuffled: false,
          comment: 'character_negative',
          strs: ['bad anatomy'],
          prompts: [],
        ),
      ],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

    final parameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];

    expect(parameters['characterPrompts'].single['prompt'], 'red hair');
    expect(parameters['characterPrompts'].single['uc'], 'bad anatomy');
    expect(
      parameters['v4_prompt']['caption']['char_captions']
          .single['char_caption'],
      'red hair',
    );
    expect(
      parameters['v4_negative_prompt']['caption']['char_captions']
          .single['char_caption'],
      'bad anatomy',
    );
  });

  test('V4.5 precise reference uses director fields and skips Vibe Transfer',
      () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['positive prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['negative prompt'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(
        model: 'nai-diffusion-4-5-full',
        nSamples: 1,
      ),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );
    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'vibe.naiv4vibe',
      vibeB64: 'vibe-b64',
      referenceStrength: 0.2,
    ));
    config.preciseReferenceConfigList.addAll([
      PreciseReferenceConfig(
        imageB64: 'image-a',
        fileName: 'a.png',
        type: PreciseReferenceType.characterAndStyle,
        strength: 0.75,
        fidelity: 0.4,
      ),
      PreciseReferenceConfig(
        imageB64: 'image-b',
        fileName: 'b.png',
        type: PreciseReferenceType.style,
        strength: 0.25,
        fidelity: 1.0,
        enabled: false,
      ),
    ]);
    config.setVibeEnabled(true);
    config.setPreciseReferenceEnabled(true);

    final parameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];

    expect(parameters['director_reference_images'], ['image-a']);
    expect(parameters['director_reference_descriptions'], [
      {
        'caption': {
          'base_caption': 'character&style',
          'char_captions': [],
        },
        'legacy_uc': false,
      }
    ]);
    expect(parameters['director_reference_information_extracted'], [1.0]);
    expect(parameters['director_reference_strength_values'], [0.75]);
    expect(
      parameters['director_reference_secondary_strength_values'],
      [0.6],
    );
    expect(parameters['reference_image_multiple'], isEmpty);
    expect(parameters['reference_strength_multiple'], isEmpty);
    expect(parameters['reference_information_extracted_multiple'], isEmpty);
  });

  test('precise reference is ignored outside V4.5 models', () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['positive prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['negative prompt'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(model: 'nai-diffusion-4-full'),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );
    config.preciseReferenceConfigList.add(PreciseReferenceConfig(
      imageB64: 'image-a',
      fileName: 'a.png',
    ));
    config.setPreciseReferenceEnabled(true);

    final parameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];

    expect(parameters.containsKey('director_reference_images'), isFalse);
    expect(parameters['reference_image_multiple'], isEmpty);
  });

  PayloadConfig buildPlainConfig({String model = 'nai-diffusion-4-5-full'}) {
    return PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['positive prompt'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['negative prompt'],
        prompts: [],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(model: model, randomSeed: false, seed: 5),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );
  }

  test('V4 payload uses model-specific encoding and Information Extracted', () {
    final config = buildPlainConfig();
    final vibe = VibeConfigV4(
      fileName: 'reference.png',
      referenceStrength: 0.42,
      informationExtracted: 0.73,
    );
    vibe.cacheEncoding(
      model: config.paramConfig.model,
      informationExtracted: 0.73,
      encoding: 'model-specific-encoding',
    );
    config.vibeConfigListV4.add(vibe);
    config.setVibeEnabled(true);

    final parameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];

    expect(parameters['reference_image_multiple'], ['model-specific-encoding']);
    expect(parameters['reference_strength_multiple'], [0.42]);
    expect(parameters['reference_information_extracted_multiple'], [0.73]);
  });

  test('disabled Vibe and Precise Reference resources stay out of payload', () {
    final config = buildPlainConfig();
    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'vibe.naiv4vibe',
      vibeB64: 'vibe-b64',
      referenceStrength: 0.2,
    ));
    config.preciseReferenceConfigList.add(PreciseReferenceConfig(
      imageB64: 'reference-b64',
      fileName: 'reference.png',
    ));

    final parameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];

    expect(parameters['reference_image_multiple'], isEmpty);
    expect(parameters.containsKey('director_reference_images'), isFalse);
  });

  test('Enhance overrides seed and appends its prompt suffix only in payload',
      () {
    final config = buildPlainConfig();
    config.i2iConfig.setUseRandomSeed(true);
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: null,
      width: 1280,
      height: 1856,
      strength: 0.3,
      noise: 0.0,
      addOriginalImage: true,
      composite: null,
      summary: 'Enhance test',
    );

    final result = GeneratePayloadUseCase(
      payloadConfig: config,
      i2iPlan: plan,
      seedOverride: 1504662765,
      promptSuffix: '-2::upscaled, blurry::,',
      applyPlainI2iCompatibilityFields: false,
    )();
    final parameters = result.payload['parameters'] as Map<String, dynamic>;

    expect(
      result.payload['input'],
      'positive prompt, -2::upscaled, blurry::,',
    );
    expect(
      parameters['v4_prompt']['caption']['base_caption'],
      'positive prompt, -2::upscaled, blurry::,',
    );
    expect(parameters['seed'], 1504662765);
    expect(parameters['extra_noise_seed'], 1504662764);
    expect(parameters['strength'], 0.3);
    expect(parameters['noise'], 0.0);
    expect(parameters, isNot(contains('color_correct')));
    expect(parameters, isNot(contains('sm')));
    expect(parameters, isNot(contains('sm_dyn')));
    expect(config.paramConfig.seed, 5);
    expect(config.rootPromptConfig.strs, ['positive prompt']);
    expect(config.overridePrompt, isEmpty);
  });

  test('legacy I2I random flag cannot override a fixed global seed', () {
    final config = buildPlainConfig();
    config.i2iConfig.setUseRandomSeed(true);
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: null,
      width: 640,
      height: 960,
      strength: 0.55,
      noise: 0.1,
      addOriginalImage: true,
      composite: null,
      summary: 'img2img random seed test',
    );

    final i2iParameters = GeneratePayloadUseCase(
      payloadConfig: config,
      i2iPlan: plan,
    )()
        .payload['parameters'] as Map<String, dynamic>;
    expect(i2iParameters['seed'], 5);
    expect(i2iParameters['extra_noise_seed'], 4);
    expect(i2iParameters['color_correct'], isFalse);
    expect(i2iParameters['sm'], isFalse);
    expect(i2iParameters['sm_dyn'], isFalse);
    final repeatedI2iParameters = GeneratePayloadUseCase(
      payloadConfig: config,
      i2iPlan: plan,
    )()
        .payload['parameters'] as Map<String, dynamic>;
    expect(repeatedI2iParameters['seed'], i2iParameters['seed']);
    expect(
      repeatedI2iParameters['extra_noise_seed'],
      i2iParameters['extra_noise_seed'],
    );
    final unrelatedImg2ImgParameters = GeneratePayloadUseCase(
      payloadConfig: config,
      i2iPlan: plan,
    )()
        .payload['parameters'] as Map<String, dynamic>;
    expect(unrelatedImg2ImgParameters['seed'], 5);

    final textToImageParameters = GeneratePayloadUseCase(
      payloadConfig: config,
    )()
        .payload['parameters'] as Map<String, dynamic>;
    expect(textToImageParameters['seed'], 5);
    expect(config.paramConfig.randomSeed, isFalse);
    expect(config.paramConfig.seed, 5);
  });

  test('global random mode gives new I2I tasks fresh coherent seeds', () {
    final config = buildPlainConfig();
    config.paramConfig.randomSeed = true;
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: null,
      width: 640,
      height: 960,
      strength: 0.55,
      noise: 0.1,
      addOriginalImage: true,
      composite: null,
      summary: 'img2img random seed test',
    );

    final parameterSets = List.generate(
      8,
      (_) => GeneratePayloadUseCase(
        payloadConfig: config,
        i2iPlan: plan,
      )()
          .payload['parameters'] as Map<String, dynamic>,
    );

    expect(parameterSets.map((parameters) => parameters['seed']).toSet().length,
        greaterThan(1));
    for (final parameters in parameterSets) {
      final seed = parameters['seed'] as int;
      expect(parameters['extra_noise_seed'], (seed - 1) & 0xFFFFFFFF);
    }
  });

  test('random generation can use the complete unsigned 32-bit seed range', () {
    final config = buildPlainConfig()..paramConfig.randomSeed = true;
    final random = _UpperBoundRandom();
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: null,
      width: 640,
      height: 960,
      strength: 0.55,
      noise: 0.1,
      addOriginalImage: true,
      composite: null,
      summary: 'full seed range',
    );

    final parameters = GeneratePayloadUseCase(
      payloadConfig: config,
      i2iPlan: plan,
      random: random,
    )()
        .payload['parameters'] as Map<String, dynamic>;

    expect(random.requestedMax, 0x100000000);
    expect(parameters['seed'], 0xFFFFFFFF);
    expect(parameters['extra_noise_seed'], 0xFFFFFFFE);
  });

  test('Enhance prompt suffix does not duplicate a trailing comma', () {
    final config = buildPlainConfig();
    config.rootPromptConfig.strs = ['positive prompt,'];
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: null,
      width: 1280,
      height: 1856,
      strength: 0.5,
      noise: 0.0,
      addOriginalImage: true,
      composite: null,
      summary: 'Enhance comma test',
    );

    final result = GeneratePayloadUseCase(
      payloadConfig: config,
      i2iPlan: plan,
      promptSuffix: '-2::upscaled, blurry::,',
    )();
    final parameters = result.payload['parameters'] as Map<String, dynamic>;

    expect(
      result.payload['input'],
      'positive prompt, -2::upscaled, blurry::,',
    );
    expect(
      parameters['v4_prompt']['caption']['base_caption'],
      'positive prompt, -2::upscaled, blurry::,',
    );
  });

  test('img2img plan switches action and adds image parameters', () {
    final config = buildPlainConfig();
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: null,
      width: 640,
      height: 960,
      strength: 0.55,
      noise: 0.1,
      addOriginalImage: true,
      composite: null,
      summary: 'img2img test',
    );

    final result =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: plan)();
    final parameters = result.payload['parameters'];

    expect(result.payload['action'], 'img2img');
    expect(result.payload['model'], 'nai-diffusion-4-5-full');
    expect(parameters['image'], 'aW1hZ2U=');
    expect(parameters['strength'], 0.55);
    expect(parameters['noise'], 0.1);
    expect(parameters['width'], 640);
    expect(parameters['height'], 960);
    expect(parameters['extra_noise_seed'], 4);
    expect(parameters.containsKey('mask'), isFalse);
    expect(parameters.containsKey('inpaintImg2ImgStrength'), isFalse);
    expect(result.comment, contains('img2img test'));
  });

  test('inpaint always requests raw pixels for official local compositing', () {
    final config = buildPlainConfig();
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: 'bWFzaw==',
      blendMaskB64: 'YmxlbmQ=',
      width: 1024,
      height: 1024,
      strength: 0.6,
      noise: 0,
      addOriginalImage: true,
      composite: null,
      summary: 'inpaint test',
    );

    final result =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: plan)();
    final parameters = result.payload['parameters'];

    expect(result.payload['action'], 'infill');
    expect(result.payload['model'], 'nai-diffusion-4-5-full-inpainting');
    expect(parameters['image'], 'aW1hZ2U=');
    expect(parameters['mask'], 'bWFzaw==');
    expect(parameters.values, isNot(contains('YmxlbmQ=')));
    expect(parameters['add_original_image'], isFalse);
    expect(parameters['strength'], 0.7);
    expect(parameters['noise'], 0.2);
    expect(parameters['inpaintImg2ImgStrength'], 0.6);
    expect(parameters['img2img'], {
      'strength': 0.6,
      'color_correct': true,
    });
    expect(parameters['extra_noise_seed'], 4);
  });

  test('V5 inpainting uses Full and launch-safe Curated model routing', () {
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: 'bWFzaw==',
      width: 1024,
      height: 1024,
      strength: 1,
      noise: 0,
      addOriginalImage: false,
      composite: null,
      summary: 'V5 inpaint',
    );

    final full = GeneratePayloadUseCase(
      payloadConfig: buildPlainConfig(model: 'nai-diffusion-5-full'),
      i2iPlan: plan,
    )();
    final curated = GeneratePayloadUseCase(
      payloadConfig: buildPlainConfig(model: 'nai-diffusion-5-curated'),
      i2iPlan: plan,
    )();

    expect(full.payload['model'], 'nai-diffusion-5-full-inpainting');
    expect(
      curated.payload['model'],
      'nai-diffusion-4-5-curated-inpainting',
    );
  });

  test('inpaint plan at full strength omits the img2img blend object', () {
    final config = buildPlainConfig(model: 'nai-diffusion-3');
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: 'bWFzaw==',
      width: 1024,
      height: 1024,
      strength: 1.0,
      noise: 0,
      addOriginalImage: false,
      composite: null,
      summary: 'inpaint full strength',
    );

    final result =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: plan)();
    final parameters = result.payload['parameters'];

    expect(result.payload['action'], 'infill');
    expect(result.payload['model'], 'nai-diffusion-3-inpainting');
    expect(parameters['add_original_image'], isFalse);
    expect(parameters['inpaintImg2ImgStrength'], 1.0);
    expect(parameters.containsKey('img2img'), isFalse);
  });

  test(
      'suggestedFileName extracts prefixes from checked prompt nodes across base and character configs',
      () {
    final artist = PromptConfig(
      comment: '画师',
      useAsFileNamePrefix: true,
      selectionMethod: 'all',
      strs: ['artist:anmi'],
      prompts: [],
    );
    final costume = PromptConfig(
      comment: '服装',
      useAsFileNamePrefix: true,
      selectionMethod: 'all',
      strs: ['school uniform'],
      prompts: [],
    );
    final charPrompt = PromptConfig(
      comment: '表情',
      useAsFileNamePrefix: true,
      selectionMethod: 'all',
      strs: ['smile'],
      prompts: [],
    );

    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        type: 'config',
        selectionMethod: 'all',
        strs: [],
        prompts: [artist, costume],
      ),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [
        CharacterConfig(
          positions: [],
          positivePromptConfig: charPrompt,
          negativePromptConfig: PromptConfig(strs: [], prompts: []),
          gender: CharacterConfig.genderOther,
          enabled: true,
        ),
      ],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

    final result = GeneratePayloadUseCase(payloadConfig: config)();
    expect(result.suggestedFileName, 'artist:anmi-school uniform-smile');
  });

  test(
      'V5 free-position character writes continuous coords and forces use_coords',
      () {
    final config = PayloadConfig(
      rootPromptConfig: PromptConfig(
        shuffled: false,
        strs: ['scene'],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        strs: ['negative'],
        prompts: [],
      ),
      characterConfigList: [
        CharacterConfig(
          positions: const [],
          freeCenter: const Point<double>(0.244, 0.541),
          positivePromptConfig: PromptConfig(
            shuffled: false,
            strs: ['girl, misaka_mikoto'],
            prompts: [],
          ),
          negativePromptConfig: PromptConfig(
            shuffled: false,
            strs: ['bad anatomy'],
            prompts: [],
          ),
          gender: CharacterConfig.genderUnset,
          enabled: true,
        ),
      ],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

    final result = GeneratePayloadUseCase(payloadConfig: config)();
    final parameters = result.payload['parameters'] as Map<String, dynamic>;

    final caption = (parameters['v4_prompt'] as Map)['caption'] as Map;
    final centers =
        ((caption['char_captions'] as List).single as Map)['centers'] as List;
    expect(centers.single, {'x': 0.244, 'y': 0.541});

    final charPrompts = parameters['characterPrompts'] as List;
    expect(
      (charPrompts.single as Map)['center'],
      {'x': 0.244, 'y': 0.541},
    );

    expect(parameters['v4_prompt']['use_coords'], isTrue);
    expect(result.comment, contains('Character 1 at x:0.244, y:0.541'));
  });

  test('transparent background appends prompt suffix and sends V5 tag hint',
      () {
    final config = buildPlainConfig(model: 'nai-diffusion-5-full');
    config.paramConfig.transparentBackground = true;

    final result = GeneratePayloadUseCase(payloadConfig: config)();
    final parameters = result.payload['parameters'] as Map<String, dynamic>;

    expect(result.payload['input'], 'positive prompt, transparent background');
    expect(
      parameters['v4_prompt']['caption']['base_caption'],
      'positive prompt, transparent background',
    );
    expect(parameters['tag_hint_transparent_background'], isTrue);
  });
}
