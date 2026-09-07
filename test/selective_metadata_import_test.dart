import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/metadata_import_options.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';

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
    expect(availability.characters, isTrue);

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

  test('explicit empty metadata character lists clear existing characters', () {
    final config = _config();
    config.fixedProfile.characterConfigList = [
      CharacterConfig(
        positions: const [],
        positivePromptConfig:
            PayloadConfig.fixedPromptConfig('stale character'),
        negativePromptConfig:
            PayloadConfig.fixedPromptConfig('stale character negative'),
        gender: CharacterConfig.genderUnset,
        enabled: true,
      ),
    ];
    const metadata = {
      'seed': 246813579,
      'v4_prompt': {
        'caption': {
          'base_caption': 'solo subject',
          'char_captions': <Object>[],
        },
        'use_coords': false,
      },
      'v4_negative_prompt': {
        'caption': {
          'base_caption': 'lowres',
          'char_captions': <Object>[],
        },
      },
    };

    final availability = config.metadataImportAvailability(metadata);
    expect(availability.characters, isTrue);

    final loaded = config.importMetadataSelectively(
      metadata,
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: true,
        characters: true,
        settings: true,
        seed: true,
      ),
    );

    expect(loaded, greaterThan(0));
    expect(config.fixedProfile.characterConfigList, isEmpty);
    expect(config.fixedProfile.paramConfig.randomSeed, isFalse);
    expect(config.fixedProfile.paramConfig.seed, 246813579);
  });

  test('V5 metadata import reproduces every generation-effective field', () {
    final original = _config();
    original
      ..promptMode = PromptMode.fixed
      ..fixedProfile.rootPromptConfig =
          PayloadConfig.fixedPromptConfig('base prompt')
      ..fixedProfile.negativePromptConfig =
          PayloadConfig.fixedPromptConfig('negative prompt', negative: true)
      ..fixedProfile.characterConfigList = [
        CharacterConfig(
          positions: const [],
          freeCenter: const Point<double>(0.244, 0.541),
          positivePromptConfig:
              PayloadConfig.fixedPromptConfig('character prompt'),
          negativePromptConfig: PayloadConfig.fixedPromptConfig(
            'character negative',
            negative: true,
          ),
          gender: CharacterConfig.genderUnset,
          enabled: true,
        ),
      ]
      ..fixedProfile.paramConfig = ParamConfig(
        model: 'nai-diffusion-5-full',
        sizes: const [GenerationSize(width: 1024, height: 1024)],
        scale: 6.25,
        sampler: 'k_dpmpp_2m',
        steps: 41,
        randomSeed: false,
        seed: 246813579,
        nSamples: 2,
        dynamicThresholding: true,
        controlNetStrength: 0.75,
        legacy: true,
        uncondScale: 0.5,
        cfgRescale: 0.35,
        noiseSchedule: 'exponential',
        varietyPlus: true,
        deliberateEulerAncestralBug: false,
        preferBrownian: true,
        straightAlpha: false,
        tagHintQt: 1,
        tagHintUcPreset: 2,
        transparentBackground: true,
        autoPosition: false,
        legacyUc: true,
      );
    final originalPayload = GeneratePayloadUseCase(payloadConfig: original)();
    final metadata = Map<String, dynamic>.from(
      originalPayload.payload['parameters'] as Map<String, dynamic>,
    )
      ..['model_name'] = 'NovelAI Diffusion V5'
      ..['model_hash'] = '0ADF9AB7';

    final imported = _config();
    imported.importMetadataSelectively(
      metadata,
      prompt: originalPayload.payload['input'] as String,
      model: originalPayload.payload['model'] as String,
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: true,
        characters: true,
        settings: true,
        seed: true,
      ),
    );
    final importedPayload = GeneratePayloadUseCase(payloadConfig: imported)();

    expect(importedPayload.payload, originalPayload.payload);
  });

  test('missing metadata fields reset stale values instead of inheriting them',
      () {
    final config = _config();
    config.fixedProfile
      ..characterConfigList = [
        CharacterConfig(
          positions: const [],
          positivePromptConfig: PayloadConfig.fixedPromptConfig('stale role'),
          negativePromptConfig: PayloadConfig.fixedPromptConfig(
            'stale role negative',
            negative: true,
          ),
          gender: CharacterConfig.genderUnset,
          enabled: true,
        ),
      ]
      ..paramConfig = ParamConfig(
        model: 'nai-diffusion-5-full',
        steps: 49,
        scale: 9.5,
        randomSeed: false,
        seed: 987654321,
        varietyPlus: true,
        transparentBackground: true,
        legacyV3Extend: true,
      );
    config
      ..i2iEnabled = true
      ..vibeEnabled = true
      ..preciseReferenceEnabled = true;

    final loaded = config.importMetadataSelectively(
      const {'width': 832, 'height': 1216},
      model: 'nai-diffusion-5-full',
      options: const MetadataImportOptions(
        prompt: false,
        undesiredContent: true,
        characters: true,
        settings: true,
        seed: true,
      ),
    );

    expect(loaded, greaterThan(0));
    expect(config.fixedProfile.characterConfigList, isEmpty);
    expect(config.fixedProfile.paramConfig.steps, 23);
    expect(config.fixedProfile.paramConfig.scale, 7.0);
    expect(config.fixedProfile.paramConfig.varietyPlus, isFalse);
    expect(config.fixedProfile.paramConfig.transparentBackground, isFalse);
    expect(config.fixedProfile.paramConfig.legacyV3Extend, isFalse);
    expect(config.fixedProfile.paramConfig.randomSeed, isTrue);
    expect(config.i2iEnabled, isFalse);
    expect(config.vibeEnabled, isFalse);
    expect(config.preciseReferenceEnabled, isFalse);
  });

  test('missing positive prompt clears stale fixed prompt by default', () {
    final config = _config();
    const metadata = {'width': 832, 'height': 1216};

    final availability = config.metadataImportAvailability(metadata);
    expect(availability.prompt, isTrue);

    config.importMetadataSelectively(
      metadata,
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: false,
        characters: false,
        settings: false,
        seed: false,
      ),
    );

    expect(config.fixedProfile.rootPromptConfig.strs, isEmpty);
  });

  test('resolved V5 model preserves free character centers without model tags',
      () {
    final config = _config();
    const metadata = {
      'v4_prompt': {
        'use_coords': true,
        'caption': {
          'base_caption': 'base',
          'char_captions': [
            {
              'char_caption': 'character',
              'centers': [
                {'x': 0.244, 'y': 0.541},
              ],
            },
          ],
        },
      },
    };

    config.importMetadataSelectively(
      metadata,
      model: 'nai-diffusion-5-curated',
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: false,
        characters: true,
        settings: true,
        seed: false,
      ),
    );

    final character = config.fixedProfile.characterConfigList.single;
    expect(character.positions, isEmpty);
    expect(character.freeCenter, const Point<double>(0.244, 0.541));
  });

  test('explicit null metadata clears nullable V5 settings', () {
    final config = _config();
    config.fixedProfile.paramConfig = ParamConfig(
      model: 'nai-diffusion-5-full',
      randomSeed: false,
      seed: 42,
      varietyPlus: true,
      transparentBackground: true,
      deliberateEulerAncestralBug: false,
      preferBrownian: true,
      straightAlpha: false,
      tagHintQt: 3,
      tagHintUcPreset: 2,
    );

    config.importMetadataSelectively(
      const {
        'skip_cfg_above_sigma': null,
        'tag_hint_transparent_background': null,
        'deliberate_euler_ancestral_bug': null,
        'prefer_brownian': null,
        'straight_alpha': null,
        'tag_hint_qt': null,
        'tag_hint_uc_preset': null,
      },
      model: 'nai-diffusion-5-full',
      options: const MetadataImportOptions(
        prompt: false,
        undesiredContent: false,
        characters: false,
        settings: true,
        seed: false,
      ),
    );

    final imported = config.fixedProfile.paramConfig;
    expect(imported.varietyPlus, isFalse);
    expect(imported.transparentBackground, isFalse);
    expect(imported.deliberateEulerAncestralBug, isNull);
    expect(imported.preferBrownian, isNull);
    expect(imported.straightAlpha, isNull);
    expect(imported.tagHintQt, isNull);
    expect(imported.tagHintUcPreset, isNull);
    expect(imported.randomSeed, isFalse);
    expect(imported.seed, 42);
  });

  test('transparent metadata keeps the original tag order without duplicates',
      () {
    final config = _config();
    const prompt =
        'subject, transparent background, very aesthetic, masterpiece';

    config.importMetadataSelectively(
      const {
        'seed': 123,
        'tag_hint_transparent_background': true,
      },
      prompt: prompt,
      model: 'nai-diffusion-5-curated',
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: false,
        characters: false,
        settings: true,
        seed: true,
      ),
    );

    final payload = GeneratePayloadUseCase(payloadConfig: config)().payload;
    expect(payload['input'], prompt);
    expect(
      (payload['parameters'] as Map)['tag_hint_transparent_background'],
      isTrue,
    );
  });

  test('server quality_boost alias imports the legacy quality setting', () {
    final config = _config();

    config.importMetadataSelectively(
      const {'quality_boost': true},
      model: 'nai-diffusion-4-5-full',
      options: const MetadataImportOptions(
        prompt: false,
        undesiredContent: false,
        characters: false,
        settings: true,
        seed: false,
      ),
    );

    expect(config.fixedProfile.paramConfig.qualityToggle, isTrue);
  });

  test('V4.5 metadata import reproduces the complete generation request', () {
    final original = _config();
    original
      ..promptMode = PromptMode.fixed
      ..fixedProfile.rootPromptConfig =
          PayloadConfig.fixedPromptConfig('v4 base')
      ..fixedProfile.negativePromptConfig =
          PayloadConfig.fixedPromptConfig('v4 negative', negative: true)
      ..fixedProfile.characterConfigList = [
        CharacterConfig(
          positions: const [Point<int>(2, 4)],
          positivePromptConfig: PayloadConfig.fixedPromptConfig('v4 character'),
          negativePromptConfig: PayloadConfig.fixedPromptConfig(
            'v4 character negative',
            negative: true,
          ),
          gender: CharacterConfig.genderUnset,
          enabled: true,
        ),
      ]
      ..fixedProfile.paramConfig = ParamConfig(
        model: 'nai-diffusion-4-5-full',
        sizes: const [GenerationSize(width: 832, height: 1216)],
        scale: 5.5,
        sampler: 'k_euler',
        steps: 23,
        randomSeed: false,
        seed: 13579,
        nSamples: 2,
        ucPreset: 1,
        qualityToggle: true,
        dynamicThresholding: true,
        controlNetStrength: 0.8,
        cfgRescale: 0.2,
        noiseSchedule: 'karras',
        varietyPlus: true,
        deliberateEulerAncestralBug: false,
        preferBrownian: true,
        legacyV3Extend: true,
        autoPosition: false,
        legacyUc: true,
      );
    final expected = GeneratePayloadUseCase(payloadConfig: original)();
    final metadata = Map<String, dynamic>.from(
      expected.payload['parameters'] as Map<String, dynamic>,
    );

    final imported = _config();
    imported.importMetadataSelectively(
      metadata,
      prompt: expected.payload['input'] as String,
      model: expected.payload['model'] as String,
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: true,
        characters: true,
        settings: true,
        seed: true,
      ),
    );

    expect(
      GeneratePayloadUseCase(payloadConfig: imported)().payload,
      expected.payload,
    );
  });

  test('V3 metadata import reproduces the complete generation request', () {
    final original = _config();
    original
      ..promptMode = PromptMode.fixed
      ..fixedProfile.rootPromptConfig =
          PayloadConfig.fixedPromptConfig('v3 base')
      ..fixedProfile.negativePromptConfig =
          PayloadConfig.fixedPromptConfig('v3 negative', negative: true)
      ..fixedProfile.characterConfigList = []
      ..fixedProfile.paramConfig = ParamConfig(
        model: 'nai-diffusion-3',
        sizes: const [GenerationSize(width: 1216, height: 832)],
        scale: 6.0,
        sampler: 'k_dpmpp_sde',
        steps: 37,
        randomSeed: false,
        seed: 97531,
        nSamples: 3,
        ucPreset: 3,
        qualityToggle: true,
        sm: true,
        smDyn: false,
        dynamicThresholding: true,
        controlNetStrength: 0.65,
        legacy: true,
        cfgRescale: 0.4,
        noiseSchedule: 'exponential',
        varietyPlus: true,
        legacyV3Extend: true,
      );
    final expected = GeneratePayloadUseCase(payloadConfig: original)();
    final metadata = Map<String, dynamic>.from(
      expected.payload['parameters'] as Map<String, dynamic>,
    );

    final imported = _config();
    imported.importMetadataSelectively(
      metadata,
      prompt: expected.payload['input'] as String,
      model: expected.payload['model'] as String,
      options: const MetadataImportOptions(
        prompt: true,
        undesiredContent: true,
        characters: true,
        settings: true,
        seed: true,
      ),
    );

    expect(
      GeneratePayloadUseCase(payloadConfig: imported)().payload,
      expected.payload,
    );
  });
}
