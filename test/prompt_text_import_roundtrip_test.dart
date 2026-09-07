import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/metadata_import_options.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';

PayloadConfig _config() => PayloadConfig(
      rootPromptConfig: PromptConfig(strs: ['RANDOM_UNCHANGED'], prompts: []),
      negativePromptConfig:
          PromptConfig(strs: ['RANDOM_NEGATIVE'], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(model: 'nai-diffusion-5-full'),
      settings: Settings.fromJson({}),
      overridePrompt: 'FIXED_UNCHANGED',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

Map<String, dynamic> _metadata(String base,
        {List<String> characters = const ['speech bubble "OLD"']}) =>
    {
      'prompt': base,
      'model_name': 'NovelAI Diffusion V5',
      'model_hash': '0ADF9AB7',
      'v4_prompt': {
        'caption': {
          'base_caption': base,
          'char_captions': [
            for (final text in characters)
              {
                'char_caption': text,
                'centers': [
                  {'x': .5, 'y': .5}
                ]
              },
          ],
        },
        'use_coords': false,
      },
      'uc': 'negative teXt: KEEP',
    };

const _all = MetadataImportOptions(
    prompt: true,
    undesiredContent: true,
    characters: true,
    settings: true,
    seed: true);
const _promptOnly = MetadataImportOptions(
    prompt: true,
    undesiredContent: false,
    characters: false,
    settings: false,
    seed: false);

String _input(PayloadConfig config) {
  final payload = GeneratePayloadUseCase(payloadConfig: config)().payload;
  expect(payload['parameters']['v4_prompt']['caption']['base_caption'],
      payload['input']);
  return payload['input'] as String;
}

void main() {
  test('source coordinates normalize auto text before character import', () {
    final config = _config();
    final source = _metadata('portrait, teXt: LEFT\n\nRIGHT',
        characters: ['speech "RIGHT"', 'speech "LEFT"']);
    final v4 = source['v4_prompt'] as Map<String, dynamic>;
    v4['use_coords'] = true;
    final chars = v4['caption']['char_captions'] as List;
    chars[0]['centers'] = [
      {'x': .9, 'y': .5}
    ];
    chars[1]['centers'] = [
      {'x': .1, 'y': .5}
    ];
    config.importMetadataSelectively(source, options: _all);
    expect(config.overridePrompt, 'portrait');
    expect(_input(config), 'portrait, teXt: LEFT\n\nRIGHT');
    PromptTabViewmodel(payloadConfig: config)
        .setFixedCharacterPrompt(0, 'speech "NEW"');
    expect(_input(config), 'portrait, teXt: LEFT\n\nNEW');
  });

  for (final selective in [true, false]) {
    test(
        'import -> edit -> generate replaces old auto text, selective=$selective',
        () {
      final config = _config();
      final randomBefore = jsonEncode(config.randomProfile.toJson());
      final source = _metadata('portrait, teXt: OLD');
      final sourceBefore = jsonEncode(source);
      if (selective) {
        config.importMetadataSelectively(source, options: _all);
      } else {
        config.importMetadataToFixedProfile(source);
      }
      expect(config.overridePrompt, 'portrait');
      expect(_input(config), 'portrait, teXt: OLD');
      PromptTabViewmodel(payloadConfig: config)
          .setFixedCharacterPrompt(0, 'speech bubble "NEW"');
      expect(_input(config), 'portrait, teXt: NEW');
      expect(config.negativePromptConfig.strs.single, 'negative teXt: KEEP');
      expect(jsonEncode(config.randomProfile.toJson()), randomBefore);
      expect(jsonEncode(source), sourceBefore);
      final reloaded =
          PayloadConfig.fromJson(jsonDecode(jsonEncode(config.toJson())));
      expect(_input(reloaded), 'portrait, teXt: NEW');
    });
  }

  test('base dialogue edit and deletion rebuild the imported auto block', () {
    final config = _config();
    config.importMetadataToFixedProfile(
        _metadata('sign "OLD", teXt: OLD', characters: []));
    expect(config.overridePrompt, 'sign "OLD"');
    final vm = PromptTabViewmodel(payloadConfig: config);
    vm.setFixedPrompt('sign "NEW"');
    expect(_input(config), 'sign "NEW", teXt: NEW');
    vm.setFixedPrompt('sign');
    expect(_input(config), 'sign');
  });

  test('disable or remove a character removes its imported automatic text', () {
    final config = _config();
    config.importMetadataToFixedProfile(_metadata('portrait, teXt: OLD'));
    final vm = PromptTabViewmodel(payloadConfig: config);
    vm.setCharacterEnabled(0, false);
    expect(_input(config), 'portrait');
    vm.setCharacterEnabled(0, true);
    expect(_input(config), 'portrait, teXt: OLD');
    vm.removeCharacter(0);
    expect(_input(config), 'portrait');
  });

  for (final base in [
    'portrait, Text: OLD',
    'portrait, text: OLD',
    'portrait, TEXT: OLD',
    'portrait, teXt: MANUAL',
    'portrait, teXt: OLD, extra content',
    'portrait, teXt:: OLD',
  ]) {
    test('manual/nonmatching block remains untouched: $base', () {
      final config = _config();
      config.importMetadataSelectively(_metadata(base), options: _all);
      expect(config.overridePrompt, base);
    });
  }

  test('prompt-only import preserves text depending on excluded characters',
      () {
    final config = _config();
    config.importMetadataSelectively(_metadata('portrait, teXt: OLD'),
        options: _promptOnly);
    expect(config.overridePrompt, 'portrait, teXt: OLD');
    expect(_input(config), 'portrait, teXt: OLD');
    expect(config.characterConfigList, isEmpty);
  });

  test('prompt-only import can normalize a self-contained base text block', () {
    final config = _config();
    config.importMetadataSelectively(
        _metadata('sign "OLD", teXt: OLD', characters: []),
        options: _promptOnly);
    expect(config.overridePrompt, 'sign "OLD"');
  });

  test(
      'excluding characters cannot misclassify a source manual block as automatic',
      () {
    final config = _config();
    config.importMetadataSelectively(
        _metadata('sign "BASE", teXt: BASE', characters: ['"OTHER"']),
        options: _promptOnly);
    expect(config.overridePrompt, 'sign "BASE", teXt: BASE');
  });

  test('unselected base prompt is never rewritten', () {
    final config = _config();
    config.overridePrompt = 'sign "LOCAL", teXt: LOCAL';
    config.importMetadataSelectively(_metadata('portrait, teXt: OLD'),
        options: const MetadataImportOptions(
            prompt: false,
            undesiredContent: false,
            characters: true,
            settings: false,
            seed: false));
    expect(config.overridePrompt, 'sign "LOCAL", teXt: LOCAL');
  });

  test('clean import classifies auto text before stripping prompt syntax', () {
    final config = _config();
    config.importMetadataSelectively(
        _metadata('portrait, teXt: {OLD}',
            characters: ['speech bubble "{OLD}"']),
        options: const MetadataImportOptions(
            prompt: true,
            undesiredContent: true,
            characters: true,
            settings: true,
            seed: true,
            cleanImports: true));
    expect(config.overridePrompt, 'portrait');
    expect(_input(config), 'portrait, teXt: OLD');
  });

  test('append import generates text from existing and newly imported prompts',
      () {
    final config = _config();
    config.overridePrompt = 'sign "EXISTING"';
    config.importMetadataSelectively(_metadata('portrait, teXt: OLD'),
        options: const MetadataImportOptions(
            prompt: true,
            undesiredContent: false,
            characters: true,
            settings: true,
            seed: false,
            append: true));
    expect(config.overridePrompt, 'sign "EXISTING", portrait');
    expect(_input(config), 'sign "EXISTING", portrait, teXt: EXISTING\n\nOLD');
  });

  test('keep explicit conditioning when the retained model has no auto text',
      () {
    final config = _config();
    config.fixedProfile.paramConfig.model = 'nai-diffusion-4-5-full';
    config.importMetadataSelectively(_metadata('portrait, teXt: OLD'),
        options: const MetadataImportOptions(
            prompt: true,
            undesiredContent: false,
            characters: true,
            settings: false,
            seed: false));
    expect(config.overridePrompt, 'portrait, teXt: OLD');
  });

  test('Chinese multiple pieces use the same detection order as generation',
      () {
    final config = _config();
    config.importMetadataToFixedProfile(
        _metadata('portrait, teXt: 乙\n\n甲', characters: ['“甲”“乙”']));
    expect(config.overridePrompt, 'portrait');
    expect(_input(config), 'portrait, teXt: 乙\n\n甲');
    PromptTabViewmodel(payloadConfig: config)
        .setFixedCharacterPrompt(0, '“丙”“丁”');
    expect(_input(config), 'portrait, teXt: 丁\n\n丙');
  });
}
