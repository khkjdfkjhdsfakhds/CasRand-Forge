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

  test('comment lines are saved but removed from generated entries', () {
    final config = PromptConfig(
      selectionMethod: 'all',
      shuffled: false,
      strs: [
        'red hair\n# private note\nblue eyes',
        '   # comment-only entry',
        '\n  \n',
        'green eyes # real inline hash',
      ],
      prompts: [],
    );

    expect(
      config.getPrmpts().toPrompt(),
      'red hair\nblue eyes, green eyes # real inline hash',
    );
    expect(config.usableEntryCount, 2);
    expect(config.strs, contains('   # comment-only entry'));

    final restored = PromptConfig.fromJson(config.toJson());
    expect(restored.strs, config.strs);
    expect(restored.getPrmpts().toPrompt(), config.getPrmpts().toPrompt());
  });

  test('every string selection method ignores comment-only and blank entries',
      () {
    PromptConfig config(String method) => PromptConfig(
          selectionMethod: method,
          shuffled: false,
          prob: 1,
          num: 10,
          strs: const ['# note', '', 'first', '   # hidden', 'second'],
          prompts: [],
        );

    expect(config('all').getPrmpts().toPrompt(), 'first, second');
    expect(config('multiple_prob').getPrmpts().toPrompt(), 'first, second');
    expect(
      config('multiple_num').getPrmpts().toPrompt().split(', '),
      unorderedEquals(['first', 'second']),
    );

    final single = config('single');
    for (var i = 0; i < 20; i++) {
      expect(single.getPrmpts().toPrompt(), isIn(['first', 'second']));
    }

    final sequential = config('single_sequential');
    sequential.num = 1;
    expect(
      List.generate(3, (_) => sequential.getPrmpts().toPrompt()),
      ['first', 'second', 'first'],
    );
  });

  test('payload reset includes root, saved, and character prompt configs', () {
    PromptConfig sequential(String first, String second) => PromptConfig(
          selectionMethod: 'single_sequential',
          shuffled: false,
          strs: [first, second],
          prompts: [],
        );

    final root = sequential('root-1', 'root-2');
    final negative = sequential('negative-1', 'negative-2');
    final saved = sequential('saved-1', 'saved-2');
    final character = sequential('character-1', 'character-2');
    final characterNegative =
        sequential('character-negative-1', 'character-negative-2');
    final payloadConfig = PayloadConfig(
      rootPromptConfig: root,
      negativePromptConfig: negative,
      characterConfigList: [
        CharacterConfig(
          positions: [],
          positivePromptConfig: character,
          negativePromptConfig: characterNegative,
          gender: CharacterConfig.genderOther,
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
    negative.getPrmpts();
    saved.getPrmpts();
    character.getPrmpts();
    characterNegative.getPrmpts();
    expect(root.getPrmpts().toPrompt(), 'root-2');
    expect(negative.getPrmpts().toPrompt(), 'negative-2');
    expect(saved.getPrmpts().toPrompt(), 'saved-2');
    expect(character.getPrmpts().toPrompt(), 'character-2');
    expect(
      characterNegative.getPrmpts().toPrompt(),
      'character-negative-2',
    );

    payloadConfig.resetSequentialState();

    expect(root.getPrmpts().toPrompt(), 'root-1');
    expect(negative.getPrmpts().toPrompt(), 'negative-1');
    expect(saved.getPrmpts().toPrompt(), 'saved-1');
    expect(character.getPrmpts().toPrompt(), 'character-1');
    expect(
      characterNegative.getPrmpts().toPrompt(),
      'character-negative-1',
    );
  });
}
