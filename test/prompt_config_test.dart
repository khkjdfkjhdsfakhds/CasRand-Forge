import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';

void main() {
  test('sequential selection repeats each entry before advancing', () {
    final config = PromptConfig(
      selectionMethod: 'single_sequential',
      num: 2,
      shuffled: false,
      strs: ['first', 'second', 'third'],
      prompts: [],
    );

    final values = List.generate(7, (_) => config.getPrmpts().toPrompt());

    expect(
      values,
      ['first', 'first', 'second', 'second', 'third', 'third', 'first'],
    );
  });

  test('reset restarts nested sequential configs from their first entries', () {
    final child = PromptConfig(
      selectionMethod: 'single_sequential',
      num: 1,
      shuffled: false,
      strs: ['one', 'two'],
      prompts: [],
    );
    final root = PromptConfig(
      selectionMethod: 'all',
      shuffled: false,
      type: 'config',
      strs: [],
      prompts: [child],
    );

    expect(root.getPrmpts().toPrompt(), 'one');
    expect(root.getPrmpts().toPrompt(), 'two');
    root.resetSequentialState();
    expect(root.getPrmpts().toPrompt(), 'one');
  });

  test('empty sequential configs are safe and return an empty prompt', () {
    final config = PromptConfig(
      selectionMethod: 'single_sequential',
      strs: [],
      prompts: [],
    );

    expect(config.getPrmpts().toPrompt(), isEmpty);
  });

  test('payload reset includes root, saved, and character prompt configs', () {
    PromptConfig sequential(String first, String second) => PromptConfig(
          selectionMethod: 'single_sequential',
          shuffled: false,
          strs: [first, second],
          prompts: [],
        );

    final root = sequential('root-1', 'root-2');
    final saved = sequential('saved-1', 'saved-2');
    final character = sequential('character-1', 'character-2');
    final payloadConfig = PayloadConfig(
      rootPromptConfig: root,
      characterConfigList: [
        CharacterConfig(
          positions: [],
          positivePromptConfig: character,
          negativePrompt: '',
          enabled: true,
        ),
      ],
      savedPromptConfigList: [saved],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

    root.getPrmpts();
    saved.getPrmpts();
    character.getPrmpts();
    expect(root.getPrmpts().toPrompt(), 'root-2');
    expect(saved.getPrmpts().toPrompt(), 'saved-2');
    expect(character.getPrmpts().toPrompt(), 'character-2');

    payloadConfig.resetSequentialState();

    expect(root.getPrmpts().toPrompt(), 'root-1');
    expect(saved.getPrmpts().toPrompt(), 'saved-1');
    expect(character.getPrmpts().toPrompt(), 'character-1');
  });
}
