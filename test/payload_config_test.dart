import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> legacyConfigJson(String negativePrompt) => {
        'prompt_config': PromptConfig(
          shuffled: false,
          strs: ['positive'],
          prompts: [],
        ).toJson(),
        'character_config': <dynamic>[],
        'saved_config': <dynamic>[],
        'param_config': ParamConfig(
          negativePrompt: negativePrompt,
        ).toJson(),
        'settings': Settings.fromJson({}).toJson(),
      };

  test('legacy fixed negative prompt migrates into a prompt config', () {
    final config = PayloadConfig.fromJson(
      legacyConfigJson('legacy low quality, legacy bad hands'),
    );

    expect(config.negativePromptConfig.type, 'str');
    expect(config.negativePromptConfig.selectionMethod, 'all');
    expect(config.negativePromptConfig.shuffled, isFalse);
    expect(config.negativePromptConfig.comment, '负面内容');
    expect(
      config.negativePromptConfig.strs,
      ['legacy low quality, legacy bad hands'],
    );
    expect(config.negativePromptConfig.prompts, isEmpty);
    expect(
      config.toJson()['negative_prompt_config'],
      config.negativePromptConfig.toJson(),
    );
  });

  test('I2I request size persists separately from text-to-image sizes', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.i2iConfig.setRequestSize(
      const GenerationSize(width: 896, height: 1280),
      mode: I2iSizeMode.manual,
    );
    config.randomProfile.paramConfig.sizes = const [
      GenerationSize(width: 1024, height: 1024),
    ];

    final restored = PayloadConfig.fromJson(config.toJson());

    expect(
      restored.i2iConfig.requestSize,
      const GenerationSize(width: 896, height: 1280),
    );
    expect(
      restored.randomProfile.paramConfig.sizes,
      const [GenerationSize(width: 1024, height: 1024)],
    );
    expect(restored.i2iConfig.sizeMode, I2iSizeMode.manual);
  });

  test('loading a config keeps one live navigation authority', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    final navigation = config.settings.navigation;
    var notifications = 0;
    navigation.addListener(() => notifications++);
    final imported = legacyConfigJson('imported');
    imported['settings'] = {
      ...Settings.fromJson({}).toJson(),
      'navigation_schema_version': 1,
      'navigation_destinations': const [
        'settings',
        'more',
        'image_to_image',
        'generation_config',
        'image_generation',
      ],
    };

    config.loadJson(imported);

    expect(config.settings.navigation, same(navigation));
    expect(navigation.destinations, [
      AppDestination.settings,
      AppDestination.imageToImage,
      AppDestination.config,
      AppDestination.generation,
    ]);
    expect(notifications, 1);

    navigation.addFavorite(AppDestination.enhance);
    final savedSettings = config.toJson()['settings'] as Map<String, dynamic>;
    expect(
      savedSettings['navigation_destinations'],
      contains('enhance'),
    );
  });

  test('I2I random-seed override persists without changing profile seeds', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.paramConfig
      ..randomSeed = false
      ..seed = 424242;
    config.i2iConfig.setUseRandomSeed(true);

    final restored = PayloadConfig.fromJson(config.toJson());

    expect(restored.i2iConfig.useRandomSeed, isTrue);
    expect(restored.paramConfig.randomSeed, isFalse);
    expect(restored.paramConfig.seed, 424242);

    restored.loadJson({
      ...legacyConfigJson('legacy'),
      'i2i_use_random_seed': false,
    });
    expect(restored.i2iConfig.useRandomSeed, isFalse);
  });

  test('saved string negative config keeps its roll settings without wrapping',
      () {
    final savedStringConfig = PromptConfig(
      selectionMethod: 'single_sequential',
      shuffled: false,
      num: 2,
      randomBracketsUpper: 3,
      randomBracketsLower: -1,
      comment: 'Negative Prompt Roll',
      filter: 'preserved filter',
      strs: ['low quality', 'bad hands'],
      prompts: [],
    );
    final savedJson = legacyConfigJson('legacy')
      ..['negative_prompt_config'] = savedStringConfig.toJson();

    final restored = PayloadConfig.fromJson(savedJson);

    expect(restored.negativePromptConfig.type, 'str');
    expect(restored.negativePromptConfig.prompts, isEmpty);
    expect(restored.negativePromptConfig.toJson(), savedStringConfig.toJson());
    expect(
      restored.negativePromptConfig.getPrmpts().toPrompt(),
      contains('low quality'),
    );
  });

  test('saved built-in negative title migrates without changing custom titles',
      () {
    final oldBuiltIn = PromptConfig(
      selectionMethod: 'single_sequential',
      shuffled: false,
      comment: '反向提示词',
      strs: ['low quality', 'bad hands'],
      prompts: [],
    );
    final oldJson = legacyConfigJson('legacy')
      ..['negative_prompt_config'] = oldBuiltIn.toJson();

    final restored = PayloadConfig.fromJson(oldJson);

    expect(restored.negativePromptConfig.comment, '负面内容');
    expect(restored.negativePromptConfig.selectionMethod, 'single_sequential');
    expect(restored.negativePromptConfig.strs, oldBuiltIn.strs);

    final customJson = legacyConfigJson('legacy')
      ..['negative_prompt_config'] = PromptConfig(
        comment: 'My custom negative config',
        strs: ['custom'],
        prompts: [],
      ).toJson();
    restored.loadJson(customJson);

    expect(restored.negativePromptConfig.comment, 'My custom negative config');
  });

  test('nested negative prompt config survives without another wrapper', () {
    final source = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    source.negativePromptConfig = PromptConfig(
      selectionMethod: 'all',
      shuffled: false,
      type: 'config',
      comment: 'Negative Prompt',
      strs: [],
      prompts: [
        PromptConfig(
          selectionMethod: 'single_sequential',
          shuffled: false,
          num: 2,
          comment: 'Quality',
          strs: ['low quality', 'bad hands'],
          prompts: [],
        ),
      ],
    );

    final restored = PayloadConfig.fromJson(source.toJson());

    expect(
      restored.negativePromptConfig.toJson(),
      source.negativePromptConfig.toJson(),
    );
    expect(restored.negativePromptConfig.prompts, hasLength(1));
    expect(restored.negativePromptConfig.prompts.single.type, 'str');
  });

  test('metadata negative prompt only updates the isolated fixed profile', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.negativePromptConfig = PromptConfig(
      selectionMethod: 'single',
      strs: ['old one', 'old two'],
      prompts: [],
    );

    final loadedCount = config.loadParamJson({'uc': 'metadata negative'});

    expect(loadedCount, 1);
    expect(config.promptMode, PromptMode.fixed);
    expect(config.paramConfig.negativePrompt, 'metadata negative');
    expect(config.negativePromptConfig.type, 'str');
    expect(config.negativePromptConfig.selectionMethod, 'all');
    expect(config.negativePromptConfig.shuffled, isFalse);
    expect(config.negativePromptConfig.comment, '负面内容');
    expect(config.negativePromptConfig.prompts, isEmpty);
    expect(config.negativePromptConfig.strs, ['metadata negative']);
    expect(config.randomProfile.negativePromptConfig.strs, [
      'old one',
      'old two',
    ]);
    expect(config.randomProfile.paramConfig.negativePrompt, 'legacy');
  });

  test('random and fixed profiles keep every generation parameter separate',
      () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.randomProfile.paramConfig
      ..steps = 17
      ..randomSeed = true
      ..seed = 99;
    config.fixedProfile.paramConfig
      ..steps = 31
      ..randomSeed = false
      ..seed = 4242;

    config.promptMode = PromptMode.fixed;
    expect(config.paramConfig.steps, 31);
    expect(config.paramConfig.randomSeed, isFalse);
    expect(config.paramConfig.seed, 4242);

    config.promptMode = PromptMode.random;
    expect(config.paramConfig.steps, 17);
    expect(config.paramConfig.randomSeed, isTrue);
    expect(config.paramConfig.seed, 99);
  });

  test('both complete profiles survive save and restore independently', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.randomProfile.rootPromptConfig =
        PayloadConfig.fixedPromptConfig('random profile prompt');
    config.randomProfile.paramConfig
      ..model = 'nai-diffusion-4-5-curated'
      ..steps = 19
      ..scale = 4.5
      ..randomSeed = true
      ..seed = 11;
    config.fixedProfile.rootPromptConfig =
        PayloadConfig.fixedPromptConfig('fixed profile prompt');
    config.fixedProfile.negativePromptConfig =
        PayloadConfig.fixedPromptConfig('fixed negative', negative: true);
    config.fixedProfile.paramConfig
      ..model = 'nai-diffusion-4-5-full'
      ..steps = 37
      ..scale = 6.0
      ..randomSeed = false
      ..seed = 987654;
    config.promptMode = PromptMode.fixed;

    final restored = PayloadConfig.fromJson(config.toJson());

    expect(restored.promptMode, PromptMode.fixed);
    expect(
      restored.randomProfile.rootPromptConfig.strs,
      ['random profile prompt'],
    );
    expect(
        restored.randomProfile.paramConfig.model, 'nai-diffusion-4-5-curated');
    expect(restored.randomProfile.paramConfig.steps, 19);
    expect(restored.randomProfile.paramConfig.scale, 4.5);
    expect(restored.randomProfile.paramConfig.randomSeed, isTrue);
    expect(
        restored.fixedProfile.rootPromptConfig.strs, ['fixed profile prompt']);
    expect(restored.fixedProfile.negativePromptConfig.strs, ['fixed negative']);
    expect(restored.fixedProfile.paramConfig.model, 'nai-diffusion-4-5-full');
    expect(restored.fixedProfile.paramConfig.steps, 37);
    expect(restored.fixedProfile.paramConfig.scale, 6.0);
    expect(restored.fixedProfile.paramConfig.randomSeed, isFalse);
    expect(restored.fixedProfile.paramConfig.seed, 987654);
  });

  test('V4 metadata imports fixed base, negative and character prompts only',
      () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));

    config.importMetadataToFixedProfile({
      'v4_prompt': {
        'use_coords': true,
        'caption': {
          'base_caption': 'fixed base',
          'char_captions': [
            {
              'char_caption': 'red hair',
              'centers': [
                {'x': 0.1, 'y': 0.9},
              ],
            },
          ],
        },
      },
      'v4_negative_prompt': {
        'caption': {
          'base_caption': 'fixed global negative',
          'char_captions': [
            {'char_caption': 'bad anatomy'},
          ],
        },
      },
    });

    expect(config.promptMode, PromptMode.fixed);
    expect(config.fixedProfile.rootPromptConfig.strs, ['fixed base']);
    expect(config.fixedProfile.negativePromptConfig.strs,
        ['fixed global negative']);
    expect(config.fixedProfile.characterConfigList, hasLength(1));
    final character = config.fixedProfile.characterConfigList.single;
    expect(character.positivePromptConfig.strs, ['red hair']);
    expect(character.negativePromptConfig.strs, ['bad anatomy']);
    expect(character.positions.single.x, 1);
    expect(character.positions.single.y, 5);
    expect(config.randomProfile.rootPromptConfig.strs, ['positive']);
    expect(config.randomProfile.characterConfigList, isEmpty);
    expect(config.randomProfile.paramConfig.negativePrompt, 'legacy');
  });

  test('metadata use_coords is inverted into AI choice state', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));

    expect(config.loadParamJson({'use_coords': false}), 1);
    expect(config.paramConfig.autoPosition, isTrue);

    expect(config.loadParamJson({'use_coords': true}), 1);
    expect(config.paramConfig.autoPosition, isFalse);
  });

  test('V4 metadata use_coords is inverted into AI choice state', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));

    expect(
      config.loadParamJson({
        'v4_prompt': {'use_coords': false},
      }),
      1,
    );
    expect(config.paramConfig.autoPosition, isTrue);

    expect(
      config.loadParamJson({
        'v4_prompt': {'use_coords': true},
      }),
      1,
    );
    expect(config.paramConfig.autoPosition, isFalse);
  });

  test(
      'built-in defaults use the requested prompts, interval, and NAI 4.5 Full parameters',
      () async {
    const qualityPrompt = 'very aesthetic, masterpiece, no text';
    const negativePrompt =
        'lowres, artistic error, film grain, scan artifacts, worst quality, bad quality, jpeg artifacts, very displeasing, chromatic aberration, dithering, halftone, screentone, multiple views, logo, too many watermarks, negative space, blank page';
    final source = await rootBundle.loadString('assets/json/example.json');
    final config = PayloadConfig.fromJson(
      json.decode(source) as Map<String, dynamic>,
    );
    final qualityConfig = config.rootPromptConfig.prompts.singleWhere(
      (prompt) => prompt.comment == '质量',
    );

    expect(config.characterConfigList, isEmpty);
    expect(config.paramConfig.model, 'nai-diffusion-4-5-full');
    expect(config.paramConfig.scale, 5.0);
    expect(config.paramConfig.cfgRescale, 0.0);
    expect(config.settings.generationIntervalSec, 2);
    expect(qualityConfig.strs, [qualityPrompt]);
    expect(config.negativePromptConfig.type, 'str');
    expect(config.negativePromptConfig.comment, '负面内容');
    expect(config.negativePromptConfig.selectionMethod, 'all');
    expect(config.negativePromptConfig.shuffled, isFalse);
    expect(config.negativePromptConfig.prompts, isEmpty);
    expect(config.negativePromptConfig.strs, [negativePrompt]);
    expect(config.paramConfig.negativePrompt, negativePrompt);
    expect(ParamConfig().negativePrompt, negativePrompt);
  });

  test('advanced resources preserve manual disable until fully deleted', () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));

    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'vibe',
      vibeB64: 'encoded',
      referenceStrength: 0.2,
    ));
    config.noteVibeImported(wasEmpty: true);
    expect(config.vibeEnabled, isTrue);
    config.setVibeEnabled(false);
    config.noteVibeImported(wasEmpty: false);
    expect(config.vibeEnabled, isFalse);
    config.vibeConfigListV4.clear();
    config.clearVibeResourceState();
    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'new vibe',
      vibeB64: 'encoded-2',
      referenceStrength: 0.2,
    ));
    config.noteVibeImported(wasEmpty: true);
    expect(config.vibeEnabled, isTrue);
  });

  test('Vibe and Precise Reference are mutually exclusive without data loss',
      () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'vibe',
      vibeB64: 'encoded',
      referenceStrength: 0.2,
    ));
    config.preciseReferenceConfigList.add(PreciseReferenceConfig(
      imageB64: 'image',
      fileName: 'reference',
    ));

    config.setVibeEnabled(true);
    expect(config.vibeEnabled, isTrue);
    config.setPreciseReferenceEnabled(true);
    expect(config.preciseReferenceEnabled, isTrue);
    expect(config.vibeEnabled, isFalse);
    expect(config.vibeConfigListV4, hasLength(1));
  });

  test('Vibe reset waits until both NAI3 and NAI4 resource lists are empty',
      () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.vibeConfigList.add(VibeConfig(
      imageB64: 'nai3',
      fileName: 'nai3.png',
      infoExtracted: 1,
      referenceStrength: 0.3,
    ));
    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'nai4',
      vibeB64: 'nai4-vibe',
      referenceStrength: 0.2,
    ));
    config.setVibeEnabled(true);
    config.setVibeEnabled(false);

    config.vibeConfigListV4.clear();
    expect(config.hasVibeResources, isTrue);
    expect(config.vibeEnabled, isFalse);

    config.vibeConfigList.clear();
    config.clearVibeResourceState();
    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'new nai4',
      vibeB64: 'new-vibe',
      referenceStrength: 0.2,
    ));
    config.noteVibeImported(wasEmpty: true);
    expect(config.vibeEnabled, isTrue);
  });
}
