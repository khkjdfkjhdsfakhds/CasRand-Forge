import 'dart:convert';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';

PromptConfig sequence(String name, int count, {int repeat = 1}) => PromptConfig(
      selectionMethod: 'single_sequential',
      shuffled: false,
      num: repeat,
      strs: List.generate(count, (i) => '$name${i + 1}'),
      prompts: [],
    );

PromptConfig group(List<PromptConfig> children,
        {String method = 'all', int repeat = 1, double probability = 0}) =>
    PromptConfig(
      type: 'config',
      selectionMethod: method,
      num: repeat,
      prob: probability,
      shuffled: false,
      strs: [],
      prompts: children,
    );
PayloadConfig payload(PromptConfig root) =>
    PayloadConfig.fromJson({'prompt_config': root.toJson()});

void main() {
  test(
      'six entries repeated twice take twelve calls without count consuming progress',
      () {
    final config = sequence('A', 6, repeat: 2);
    expect(config.getPrmpts().toPrompt(), 'A1');
    expect(config.calculateCombinations(), 12);
    expect(config.calculateCombinations(), 12);
    expect(config.getPrmpts().toPrompt(), 'A1');
    expect(config.getPrmpts().toPrompt(), 'A2');
  });
  test(
      'nested sequential A2 B3 resumes children and returns after twelve calls',
      () {
    final config = PromptConfig(
        type: 'config',
        selectionMethod: 'single_sequential',
        shuffled: false,
        strs: [],
        prompts: [sequence('A', 2), sequence('B', 3)]);
    expect(config.calculateCombinations(), 12);
    const expected = [
      'A1',
      'B1',
      'A2',
      'B2',
      'A1',
      'B3',
      'A2',
      'B1',
      'A1',
      'B2',
      'A2',
      'B3'
    ];
    expect(List.generate(12, (_) => config.getPrmpts().toPrompt()), expected);
    expect(List.generate(12, (_) => config.getPrmpts().toPrompt()), expected);
  });

  test(
      'two reference positions use independent progress rather than advancing the template twice',
      () {
    final config = PayloadConfig.fromJson({
      'prompt_config':
          PromptConfig(strs: ['__A__ + __A__'], prompts: [], shuffled: false)
              .toJson()
    });
    final template = sequence('A', 3)..comment = 'A';
    config.savedPromptConfigList = [template];
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    expect(List.generate(3, (_) => generate().payload['input']),
        ['A1 + A1', 'A2 + A2', 'A3 + A3']);
    expect(template.getPrmpts().toPrompt(), 'A1');
  });

  test(
      'total includes actually referenced templates and negative cycles without consuming either',
      () {
    final config = PayloadConfig.fromJson({
      'prompt_config':
          PromptConfig(strs: ['__A__'], prompts: [], shuffled: false).toJson()
    });
    config.savedPromptConfigList = [
      sequence('A', 3)..comment = 'A',
      sequence('Unused', 5)
    ];
    config.negativePromptConfig = sequence('N', 2);
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    expect(config.totalCombinations, 6);
    expect(generate().payload['input'], 'A1');
    expect(config.totalCombinations, 6);
    final next = generate().payload;
    expect(next['input'], 'A2');
    expect(next['parameters']['negative_prompt'], 'N2');
  });

  test('unsupported model does not count or secretly advance character prompts',
      () {
    final config = PayloadConfig.fromJson({
      'prompt_config': PromptConfig(strs: ['base'], prompts: []).toJson()
    });
    final character = CharacterConfig.fromEmpty()
      ..positivePromptConfig = sequence('C', 3)
      ..negativePromptConfig = sequence('N', 2);
    config.characterConfigList = [character];
    config.paramConfig.model = 'nai-diffusion-3';
    expect(config.totalCombinations, 1);
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    expect(generate().payload['parameters']['characterPrompts'], isEmpty);
    config.paramConfig.model = 'nai-diffusion-5-full';
    expect(config.totalCombinations, 6);
    final first = generate().payload['parameters']['characterPrompts'][0];
    expect(first['prompt'], 'C1');
    expect(first['uc'], 'N1');
  });

  for (final (a, b, c, expected) in [
    (17, 17, 6, 102),
    (18, 18, 6, 18),
    (6, 6, 6, 6)
  ]) {
    test('parallel $a $b $c complete one synchronous cycle of $expected', () {
      final config =
          group([sequence('A', a), sequence('B', b), sequence('C', c)]);
      expect(config.calculateCombinations(), expected);
      final first =
          List.generate(expected, (_) => config.getPrmpts().toPrompt());
      expect(
          List.generate(expected, (_) => config.getPrmpts().toPrompt()), first);
    });
  }
  test('six six six with final repeat six takes thirty six', () {
    expect(
        group([sequence('A', 6), sequence('B', 6), sequence('C', 6, repeat: 6)])
            .calculateCombinations(),
        36);
  });
  test('parallel repeat state is retained even when output pairs repeat', () {
    final config =
        group([sequence('A', 3, repeat: 2), sequence('B', 2, repeat: 3)]);
    expect(config.calculateCombinations(), 6);
    expect(List.generate(6, (_) => config.getPrmpts().toPrompt()),
        ['A1, B1', 'A1, B1', 'A2, B1', 'A2, B2', 'A3, B2', 'A3, B2']);
  });
  test('different parallel repeats meet at twelve not twenty four', () {
    final config = group([sequence('A', 3, repeat: 2), sequence('B', 4)]);
    expect(config.calculateCombinations(), 12);
  });
  test('parent repeat invokes child each time rather than freezing output', () {
    final config = group([sequence('A', 3), sequence('B', 2)],
        method: 'single_sequential', repeat: 2);
    expect(config.calculateCombinations(), 12);
    const expected = [
      'A1',
      'A2',
      'B1',
      'B2',
      'A3',
      'A1',
      'B1',
      'B2',
      'A2',
      'A3',
      'B1',
      'B2'
    ];
    expect(List.generate(12, (_) => config.getPrmpts().toPrompt()), expected);
    expect(List.generate(12, (_) => config.getPrmpts().toPrompt()), expected);
  });
  for (final method in ['all', 'multiple_num', 'multiple_prob']) {
    test('deterministic $method boundary retains nested period', () {
      final config = group([sequence('A', 2), sequence('B', 3)],
          method: method, repeat: 2, probability: 1);
      expect(config.calculateCombinations(), 6);
      // multiple_num shuffles, but selection and child progress remain intact.
      for (var i = 0; i < 6; i++) {
        config.getPrmpts();
      }
      expect(config.getPrmpts().toPrompt().split(', '),
          unorderedEquals(['A1', 'B1']));
    });
  }
  for (final method in ['single', 'multiple_num', 'multiple_prob']) {
    test('actual random $method branch does not promise nested traversal', () {
      final config = group([sequence('A', 2), sequence('B', 3)],
          method: method, repeat: 1, probability: 0.5);
      expect(config.calculateCombinations(), 1);
    });
  }
  test('single random only candidate retains child repeat cycle', () {
    expect(
        group([sequence('A', 3, repeat: 2)], method: 'single')
            .calculateCombinations(),
        6);
  });
  test('probability zero neither counts nor advances child', () {
    final child = sequence('A', 3);
    final config = group([child], method: 'multiple_prob');
    expect(config.calculateCombinations(), 1);
    for (var i = 0; i < 4; i++) {
      expect(config.getPrmpts().toPrompt(), '');
    }
    config.prob = 1;
    expect(config.calculateCombinations(), 3);
    expect(config.getPrmpts().toPrompt(), 'A1');
  });
  test(
      'enabled empty child occupies a sequential slot until explicitly disabled',
      () {
    final empty = PromptConfig(strs: [], prompts: []);
    final config =
        group([sequence('A', 1), empty], method: 'single_sequential');
    expect(config.calculateCombinations(), 2);
    expect(List.generate(4, (_) => config.getPrmpts().toPrompt()),
        ['A1', '', 'A1', '']);
    empty.enabled = false;
    expect(config.calculateCombinations(), 1);
  });
  test('comment-only string entries still use the existing filtering rules',
      () {
    final config = PromptConfig(
        selectionMethod: 'single_sequential',
        strs: ['# ignored', 'A', ' ', 'B'],
        prompts: []);
    expect(config.calculateCombinations(), 2);
    expect(config.getPrmpts().toPrompt(), 'A');
    expect(config.getPrmpts().toPrompt(), 'B');
    expect(config.calculateCombinationCycle(filterEntryComments: false),
        BigInt.from(4));
  });
  test('random brackets and shuffle do not erase deterministic progress', () {
    final config = sequence('A', 3)
      ..randomBracketsLower = -2
      ..randomBracketsUpper = 2
      ..shuffled = true;
    expect(config.calculateCombinations(), 3);
    final stripped = List.generate(
        3,
        (_) =>
            config.getPrmpts().toPrompt().replaceAll(RegExp(r'[{}\[\]]'), ''));
    expect(stripped, ['A1', 'A2', 'A3']);
  });
  test(
      'fixed mode counts its own references negative and enabled character fields only',
      () {
    final config = payload(sequence('Inactive', 17))
      ..promptMode = PromptMode.fixed;
    config.rootPromptConfig =
        PromptConfig(strs: ['# __A__'], prompts: [], shuffled: false);
    config.negativePromptConfig = sequence('N', 2);
    config.savedPromptConfigList = [sequence('A', 3)..comment = 'A'];
    config.characterConfigList = [
      CharacterConfig.fromEmpty()..negativePromptConfig = sequence('CN', 5),
      CharacterConfig.fromEmpty()
        ..positivePromptConfig = sequence('OFF', 7)
        ..enabled = false
    ];
    expect(config.totalCombinations, 30);
    final result = GeneratePayloadUseCase(payloadConfig: config)().payload;
    expect(result['input'], '# A1');
    expect(result['parameters']['characterPrompts'][0]['uc'], 'CN1');
  });
  test('reference positions in alternating text entries pause independently',
      () {
    final config = payload(PromptConfig(
        selectionMethod: 'single_sequential',
        strs: ['left __A__', 'right __A__'],
        prompts: [],
        shuffled: false));
    config.savedPromptConfigList = [sequence('A', 3)..comment = 'A'];
    expect(config.totalCombinations, 6);
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    expect(List.generate(6, (_) => generate().payload['input']),
        ['left A1', 'right A1', 'left A2', 'right A2', 'left A3', 'right A3']);
  });
  test(
      'nested reference template uses independent child and repeat states per occurrence',
      () {
    final config = payload(
        PromptConfig(strs: ['__T__ + __T__'], prompts: [], shuffled: false));
    config.savedPromptConfigList = [
      group([sequence('A', 2), sequence('B', 3)], method: 'single_sequential')
        ..comment = 'T'
    ];
    expect(config.totalCombinations, 12);
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    expect(List.generate(4, (_) => generate().payload['input']),
        ['A1 + A1', 'B1 + B1', 'A2 + A2', 'B2 + B2']);
    config.resetSequentialState();
    expect(generate().payload['input'], 'A1 + A1');
  });
  test(
      'same reference in positive negative and character fields does not share progress',
      () {
    final config =
        payload(PromptConfig(strs: ['__A__'], prompts: [], shuffled: false));
    config.negativePromptConfig = PromptConfig(strs: ['__A__'], prompts: []);
    config.characterConfigList = [
      CharacterConfig.fromEmpty()
        ..positivePromptConfig = PromptConfig(strs: ['__A__'], prompts: [])
        ..negativePromptConfig = PromptConfig(strs: ['__A__'], prompts: [])
    ];
    config.savedPromptConfigList = [sequence('A', 3, repeat: 2)..comment = 'A'];
    expect(config.totalCombinations, 6);
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    for (final expected in ['A1', 'A1', 'A2']) {
      final result = generate().payload;
      expect(result['input'], expected);
      expect(result['parameters']['negative_prompt'], expected);
      expect(result['parameters']['characterPrompts'][0]['prompt'], expected);
      expect(result['parameters']['characterPrompts'][0]['uc'], expected);
    }
  });
  test(
      'reference expansion remains one pass including missing and self references',
      () {
    final config =
        payload(PromptConfig(strs: ['__A__ __missing__'], prompts: []));
    config.savedPromptConfigList = [
      PromptConfig(comment: 'A', strs: ['__B__ __A__'], prompts: []),
      sequence('B', 7)..comment = 'B'
    ];
    expect(config.totalCombinations, 1);
    expect(GeneratePayloadUseCase(payloadConfig: config)().payload['input'],
        '__B__ __A__ __missing__');
  });
  test('references under a random parent do not add a guaranteed cycle', () {
    final config = payload(PromptConfig(
        selectionMethod: 'single', strs: ['__A__', 'fixed'], prompts: []));
    config.savedPromptConfigList = [sequence('A', 7)..comment = 'A'];
    expect(config.totalCombinations, 1);
  });
  test(
      'editing one source entry resets that occurrence but leaves other nodes progressing',
      () {
    final config = payload(group([
      PromptConfig(strs: ['left __A__'], prompts: []),
      PromptConfig(strs: ['right __A__'], prompts: [])
    ]));
    final template = sequence('A', 3)..comment = 'A';
    config.savedPromptConfigList = [template];
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    expect(generate().payload['input'], 'left A1, right A1');
    config.rootPromptConfig.prompts[0].strs[0] = 'edited __A__';
    expect(generate().payload['input'], 'edited A1, right A2');
    template.strs[2] = 'updated';
    expect(generate().payload['input'], 'edited A2, right updated');
    config.savedPromptConfigList = [sequence('NEW', 2)..comment = 'A'];
    expect(generate().payload['input'], 'edited NEW1, right NEW1');
  });
  test(
      'counting and reference progress never change serialized config and reset restarts them',
      () {
    final config = payload(PromptConfig(strs: ['__A__'], prompts: []));
    config.savedPromptConfigList = [sequence('A', 3)..comment = 'A'];
    final before = jsonEncode(config.toJson());
    final generate = GeneratePayloadUseCase(payloadConfig: config);
    expect(generate().payload['input'], 'A1');
    for (var i = 0; i < 20; i++) {
      expect(config.totalCombinations, 3);
    }
    expect(generate().payload['input'], 'A2');
    expect(jsonEncode(config.toJson()), before);
    config.resetSequentialState();
    expect(generate().payload['input'], 'A1');
  });
  test('exact large cycles do not wrap or silently saturate an integer', () {
    final config = group([
      sequence('A', 1, repeat: 4000000000),
      sequence('B', 1, repeat: 4000000001)
    ]);
    expect(
        config.calculateCombinationCycle().toString(), '16000000004000000000');
    expect(config.calculateCombinations, throwsRangeError);
  });
  test('malformed legacy reference keeps its unresolved placeholder', () {
    final config = payload(PromptConfig(strs: ['__A__'], prompts: []));
    config.savedPromptConfigList = [
      PromptConfig(
          comment: 'A',
          type: 'unknown',
          selectionMethod: 'single_sequential',
          strs: ['A', 'B'],
          prompts: [])
    ];
    expect(GeneratePayloadUseCase(payloadConfig: config)().payload['input'],
        '__A__');
    expect(config.totalCombinations, 1);
  });
}
