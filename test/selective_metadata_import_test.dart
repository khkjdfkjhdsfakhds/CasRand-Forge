import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/metadata_import_options.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';

PayloadConfig _config() {
  final config = PayloadConfig(
    rootPromptConfig: PromptConfig(strs: ['random prompt'], prompts: []),
    negativePromptConfig: PromptConfig(strs: ['random negative'], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(
      model: 'nai-diffusion-5-full',
      steps: 18,
      randomSeed: true,
      seed: 7,
    ),
    settings: Settings.fromJson({}),
    overridePrompt: 'existing fixed',
    useOverridePrompt: false,
    useCharacterPromptWithOverride: false,
  );
  config.fixedProfile.negativePromptConfig = PayloadConfig.fixedPromptConfig(
      'existing fixed negative',
      negative: true);
  config.fixedProfile.paramConfig
    ..negativePrompt = 'existing fixed negative'
    ..steps = 12
    ..randomSeed = false
    ..seed = 111;
  return config;
}

void main() {
  test('selective metadata import changes only chosen fixed categories', () {
    final config = _config();
    final randomBefore = config.randomProfile.toJson();

    final availability = config.metadataImportAvailability(
      {
        'uc': 'imported negative',
        'steps': 30,
        'seed': 999,
        'width': 1024,
        'height': 1024,
      },
      prompt: 'imported positive',
      model: 'nai-diffusion-4-5-full',
    );
    expect(availability.prompt, isTrue);
    expect(availability.undesiredContent, isTrue);
    expect(availability.settings, isTrue);
    expect(availability.seed, isTrue);
    expect(availability.characters, isFalse);

    config.importMetadataSelectively(
      {
        'uc': 'imported negative',
        'steps': 30,
        'seed': 999,
        'width': 1024,
        'height': 1024,
      },
      prompt: 'imported positive',
      model: 'nai-diffusion-4-5-full',
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: false,
        characters: false,
        settings: true,
        seed: false,
      ),
    );

    expect(config.promptMode, PromptMode.fixed);
    expect(config.fixedProfile.rootPromptConfig.strs, ['imported positive']);
    expect(
      config.fixedProfile.negativePromptConfig.strs,
      ['existing fixed negative'],
    );
    expect(config.fixedProfile.paramConfig.steps, 30);
    expect(config.fixedProfile.paramConfig.model, 'nai-diffusion-4-5-full');
    expect(config.fixedProfile.paramConfig.seed, 111);
    expect(config.fixedProfile.paramConfig.randomSeed, isFalse);
    expect(config.fixedProfile.characterConfigList, isEmpty);
    expect(config.randomProfile.toJson(), randomBefore);
  });

  test('append and clean affect only newly imported prompt text', () {
    final config = _config();
    config.fixedProfile.characterConfigList = [
      CharacterConfig(
        positions: const [],
        positivePromptConfig:
            PayloadConfig.fixedPromptConfig('existing character'),
        negativePromptConfig:
            PayloadConfig.fixedPromptConfig('existing character negative'),
        gender: CharacterConfig.genderUnset,
        enabled: true,
      ),
    ];

    config.importMetadataSelectively(
      {
        'uc': '{new negative},[artifact]',
        'characterPrompts': [
          {
            'prompt': '{new character},[blue eyes]',
            'uc': '[bad hands],lowres',
          },
        ],
      },
      prompt: '{new subject},[best quality]',
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: true,
        characters: true,
        settings: false,
        seed: false,
        append: true,
        cleanImports: true,
      ),
    );

    expect(
      config.fixedProfile.rootPromptConfig.strs,
      ['existing fixed, new subject, best quality'],
    );
    expect(
      config.fixedProfile.negativePromptConfig.strs,
      ['existing fixed negative, new negative, artifact'],
    );
    expect(config.fixedProfile.characterConfigList, hasLength(2));
    expect(
      config.fixedProfile.characterConfigList.last.positivePromptConfig.strs,
      ['new character, blue eyes'],
    );
    expect(
      config.fixedProfile.characterConfigList.last.negativePromptConfig.strs,
      ['bad hands, lowres'],
    );
  });
}
