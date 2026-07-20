import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';

void main() {
  test('hidden override prompt remains stored but is not applied', () {
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

    expect(result.payload['input'], 'generated root prompt');
    expect(config.useOverridePrompt, isTrue);
    expect(config.overridePrompt, 'preserved override prompt');
    expect(config.toJson()['use_override_prompt'], isTrue);
    expect(config.toJson()['override_prompt'], 'preserved override prompt');
    expect(result.payload['parameters']['v4_prompt']['use_coords'], isFalse);
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
}
