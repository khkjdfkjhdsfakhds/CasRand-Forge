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

  test('useAsFileNamePrefix serializes and collects prefix comments in order', () {
    final artistConfig = PromptConfig(
      comment: '画师',
      useAsFileNamePrefix: true,
      strs: ['artist:anmi', 'artist:tite kubo'],
      prompts: [],
    );
    final costumeConfig = PromptConfig(
      comment: '服装',
      useAsFileNamePrefix: true,
      strs: ['school uniform', 'maid dress'],
      prompts: [],
    );
    final bgConfig = PromptConfig(
      comment: '背景',
      useAsFileNamePrefix: false,
      strs: ['beach', 'forest'],
      prompts: [],
    );
    final root = PromptConfig(
      type: 'config',
      comment: 'Root',
      strs: [],
      prompts: [artistConfig, costumeConfig, bgConfig],
    );

    expect(root.collectPrefixComments(), ['画师', '服装']);

    final json = root.toJson();
    final restored = PromptConfig.fromJson(json);
    expect(restored.collectPrefixComments(), ['画师', '服装']);
    expect(restored.prompts[0].useAsFileNamePrefix, isTrue);
    expect(restored.prompts[1].useAsFileNamePrefix, isTrue);
    expect(restored.prompts[2].useAsFileNamePrefix, isFalse);
  });

  test('calculateCombinations correctly computes total permutations across configs and characters', () {
    final artistConfig = PromptConfig(
      selectionMethod: 'single',
      strs: ['anmi', 'tite kubo', 'hokusai'], // 3
      prompts: [],
    );
    final costumeConfig = PromptConfig(
      selectionMethod: 'single_sequential',
      num: 2,
      strs: ['uniform', 'kimono'], // 2 (num is repeat count, not a multiplier)
      prompts: [],
    );
    final tagConfig = PromptConfig(
      selectionMethod: 'multiple_num',
      num: 2,
      strs: ['hat', 'glasses', 'scarf', 'gloves'], // C(4, 2) = 6
      prompts: [],
    );
    final root = PromptConfig(
      type: 'config',
      selectionMethod: 'all',
      strs: [],
      prompts: [artistConfig, costumeConfig, tagConfig],
    );

    // 3 * 2 * 6 = 36
    expect(root.calculateCombinations(), 36);

    final charPrompt = PromptConfig(
      selectionMethod: 'single',
      strs: ['smile', 'frown'], // 2
      prompts: [],
    );
    final payloadConfig = PayloadConfig(
      rootPromptConfig: root,
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

    // 36 * 2 = 72
    expect(payloadConfig.totalCombinations, 72);
  });

  test('calculateCombinations on config nodes with multiple_num', () {
    final c1 = PromptConfig(selectionMethod: 'single', strs: ['a', 'b'], prompts: []); // 2
    final c2 = PromptConfig(selectionMethod: 'single', strs: ['c', 'd', 'e'], prompts: []); // 3
    final c3 = PromptConfig(selectionMethod: 'single', strs: ['f', 'g', 'h', 'i'], prompts: []); // 4

    // Choosing 2 of the 3 configs: (2*3) + (2*4) + (3*4) = 6 + 8 + 12 = 26
    final folder = PromptConfig(
      type: 'config',
      selectionMethod: 'multiple_num',
      num: 2,
      strs: [],
      prompts: [c1, c2, c3],
    );
    expect(folder.calculateCombinations(), 26);
  });
}
