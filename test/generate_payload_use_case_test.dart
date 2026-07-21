import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';

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

    final parameters =
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters'];

    expect(parameters.containsKey('director_reference_images'), isFalse);
    expect(parameters['reference_image_multiple'], isEmpty);
  });
}
