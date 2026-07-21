import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';

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

  test('metadata negative prompt replaces the roll config with a fixed value',
      () {
    final config = PayloadConfig.fromJson(legacyConfigJson('legacy'));
    config.negativePromptConfig = PromptConfig(
      selectionMethod: 'single',
      strs: ['old one', 'old two'],
      prompts: [],
    );

    final loadedCount = config.loadParamJson({'uc': 'metadata negative'});

    expect(loadedCount, 1);
    expect(config.paramConfig.negativePrompt, 'metadata negative');
    expect(config.negativePromptConfig.type, 'str');
    expect(config.negativePromptConfig.selectionMethod, 'all');
    expect(config.negativePromptConfig.shuffled, isFalse);
    expect(config.negativePromptConfig.comment, '负面内容');
    expect(config.negativePromptConfig.prompts, isEmpty);
    expect(config.negativePromptConfig.strs, ['metadata negative']);
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
      'built-in defaults use NAI 4.5 Full parameters, a fixed negative prompt, and no characters',
      () async {
    final source = await rootBundle.loadString('assets/json/example.json');
    final config = PayloadConfig.fromJson(
      json.decode(source) as Map<String, dynamic>,
    );

    expect(config.characterConfigList, isEmpty);
    expect(config.paramConfig.model, 'nai-diffusion-4-5-full');
    expect(config.paramConfig.scale, 5.0);
    expect(config.paramConfig.cfgRescale, 0.0);
    expect(config.negativePromptConfig.type, 'str');
    expect(config.negativePromptConfig.comment, '负面内容');
    expect(config.negativePromptConfig.selectionMethod, 'all');
    expect(config.negativePromptConfig.shuffled, isFalse);
    expect(config.negativePromptConfig.prompts, isEmpty);
    expect(config.negativePromptConfig.strs, hasLength(1));
    expect(config.negativePromptConfig.getPrmpts().toPrompt(), isNotEmpty);
  });
}
