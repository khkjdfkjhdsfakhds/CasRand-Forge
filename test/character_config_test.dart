import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';

void main() {
  test('new characters use simple empty prompts, C3, and blank gender', () {
    final config = CharacterConfig.fromEmpty();

    expect(config.positions, [const Point<int>(3, 3)]);
    expect(config.gender, CharacterConfig.genderUnset);
    expect(config.positivePromptConfig.type, 'str');
    expect(config.positivePromptConfig.comment, '提示词');
    expect(config.positivePromptConfig.strs, isEmpty);
    expect(config.negativePromptConfig.type, 'str');
    expect(config.negativePromptConfig.comment, '负面内容');
    expect(config.negativePromptConfig.strs, isEmpty);
  });

  test('Female and Male replace a leading gender tag without losing body', () {
    final config = CharacterConfig.fromEmpty();
    config.positivePromptConfig.strs = ['1boy, blue eyes, smile'];

    config.setGender(CharacterConfig.genderFemale);
    expect(config.positivePromptConfig.strs.single, 'girl, blue eyes, smile');

    config.setGender(CharacterConfig.genderMale);
    expect(config.positivePromptConfig.strs.single, 'boy, blue eyes, smile');
  });

  test('selecting Other from blank does not modify prompt content', () {
    final config = CharacterConfig.fromEmpty();
    config.positivePromptConfig.strs = ['girl, red hair'];

    config.setGender(CharacterConfig.genderOther);

    expect(config.gender, CharacterConfig.genderOther);
    expect(config.positivePromptConfig.strs.single, 'girl, red hair');
  });

  test('gender prefix skips leading comment-only and blank entries', () {
    final config = CharacterConfig.fromEmpty()
      ..positivePromptConfig.strs = [
        '# character notes',
        '   ',
        '# notes inside the entry\nportrait',
      ];

    config.setGender(CharacterConfig.genderFemale);

    expect(config.positivePromptConfig.strs, [
      '# character notes',
      '   ',
      '# notes inside the entry\ngirl, portrait',
    ]);

    config.setGender(CharacterConfig.genderOther);
    expect(config.positivePromptConfig.strs, [
      '# character notes',
      '   ',
      '# notes inside the entry\nportrait',
    ]);
  });

  test('gender prefix finds the first usable nested string config', () {
    final notes = PromptConfig(
      shuffled: false,
      strs: ['# notes only'],
      prompts: [],
    );
    final prompt = PromptConfig(
      shuffled: false,
      strs: ['portrait'],
      prompts: [],
    );
    final config = CharacterConfig.fromEmpty()
      ..positivePromptConfig = PromptConfig(
        type: 'config',
        strs: [],
        prompts: [notes, prompt],
      );

    config.setGender(CharacterConfig.genderFemale);

    expect(notes.strs, ['# notes only']);
    expect(prompt.strs, ['girl, portrait']);
  });

  test('switching Female or Male to Other removes only binary prefixes', () {
    final cases = {
      'girl, red hair': 'red hair',
      'boy, blue eyes': 'blue eyes',
      '1girl, smile': 'smile',
      '1boy, portrait': 'portrait',
      'other, red hair': 'other, red hair',
      '1other, blue eyes': '1other, blue eyes',
      'girlfriend, smile': 'girlfriend, smile',
      'landscape': 'landscape',
    };

    for (final entry in cases.entries) {
      final config = CharacterConfig.fromEmpty()
        ..gender = CharacterConfig.genderFemale
        ..positivePromptConfig.strs = [entry.key];

      config.setGender(CharacterConfig.genderOther);

      expect(config.positivePromptConfig.strs.single, entry.value);
    }
  });

  test('gender updates the first nested string leaf or creates one', () {
    final firstLeaf = PromptConfig(
      shuffled: false,
      comment: 'First',
      strs: ['portrait'],
      prompts: [],
    );
    final nested = CharacterConfig(
      positions: [CharacterConfig.defaultPosition],
      positivePromptConfig: PromptConfig(
        type: 'config',
        shuffled: false,
        comment: 'Nested',
        strs: [],
        prompts: [firstLeaf],
      ),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      gender: CharacterConfig.genderOther,
      enabled: true,
    );

    nested.setGender(CharacterConfig.genderFemale);
    expect(firstLeaf.strs.single, 'girl, portrait');

    final emptyNested = CharacterConfig(
      positions: [CharacterConfig.defaultPosition],
      positivePromptConfig: PromptConfig(
        type: 'config',
        shuffled: false,
        comment: 'Nested',
        strs: [],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      gender: CharacterConfig.genderOther,
      enabled: true,
    );
    emptyNested.setGender(CharacterConfig.genderMale);

    expect(emptyNested.positivePromptConfig.prompts, hasLength(1));
    expect(
      emptyNested.positivePromptConfig.prompts.single.strs,
      ['boy,'],
    );
  });

  test('legacy character JSON migrates without changing prompt meaning', () {
    Map<String, dynamic> legacyJson({
      String title = 'Unnamed config',
      List<Map<String, int>> positions = const [
        {'x': 1, 'y': 2},
        {'x': 5, 'y': 4},
      ],
    }) =>
        {
          'positions': positions,
          'positivePromptConfig': PromptConfig(
            shuffled: false,
            comment: title,
            strs: ['1girl, original body'],
            prompts: [],
          ).toJson(),
          'negativePrompt': 'legacy bad hands',
          'enabled': true,
        };

    final migrated = CharacterConfig.fromJson(legacyJson());

    expect(migrated.positions, [const Point<int>(1, 2)]);
    expect(migrated.gender, CharacterConfig.genderUnset);
    expect(migrated.positivePromptConfig.comment, '提示词');
    expect(migrated.positivePromptConfig.strs, ['1girl, original body']);
    expect(migrated.negativePromptConfig.comment, '负面内容');
    expect(migrated.negativePromptConfig.strs, ['legacy bad hands']);
    expect(migrated.toJson(), containsPair('gender', ''));
    expect(migrated.toJson(), contains('negativePromptConfig'));
    expect(migrated.toJson(), isNot(contains('negativePrompt')));

    final emptyPosition = CharacterConfig.fromJson(
      legacyJson(positions: const []),
    );
    expect(emptyPosition.positions, [CharacterConfig.defaultPosition]);

    final customTitle = CharacterConfig.fromJson(
      legacyJson(title: 'My character prompt'),
    );
    expect(customTitle.positivePromptConfig.comment, 'My character prompt');

    final explicitOther = CharacterConfig.fromJson(
      legacyJson()..['gender'] = CharacterConfig.genderOther,
    );
    expect(explicitOther.gender, CharacterConfig.genderOther);
  });

  test('new character JSON preserves negative PromptConfig roll settings', () {
    final source = CharacterConfig.fromEmpty()
      ..negativePromptConfig = PromptConfig(
        selectionMethod: 'single_sequential',
        shuffled: false,
        comment: '负面内容',
        strs: ['one', 'two'],
        prompts: [],
      );

    final restored = CharacterConfig.fromJson(source.toJson());

    expect(restored.negativePromptConfig.toJson(),
        source.negativePromptConfig.toJson());
    expect(restored.negativePromptConfig.getPrmpts().toPrompt(), 'one');
    expect(restored.negativePromptConfig.getPrmpts().toPrompt(), 'two');
  });

  group('V5 free-position continuous coordinates', () {
    test('freeCenter is exposed and persisted through toJson/fromJson', () {
      final config = CharacterConfig.fromEmpty()
        ..freeCenter = const Point<double>(0.244, 0.541);

      final json = config.toJson();
      expect(json['freeCenter'], {'x': 0.244, 'y': 0.541});

      final restored = CharacterConfig.fromJson(json);
      expect(restored.freeCenter, const Point<double>(0.244, 0.541));
      expect(restored.positions, isNotEmpty); // legacy grid untouched
    });

    test('getPrompt uses freeCenter pixel-free normalized coords', () {
      final config = CharacterConfig.fromEmpty()
        ..freeCenter = const Point<double>(0.244, 0.541);

      final result = config.getPrompt();
      expect(result.center, const Point<double>(0.244, 0.541));
      expect(result.isFreePosition, isTrue);
    });

    test('legacy positions still resolve to normalized grid center', () {
      final config = CharacterConfig.fromEmpty()
        ..positions = [const Point<int>(5, 5)]
        ..freeCenter = null;

      final result = config.getPrompt();
      // doubleMapping[5] == 0.9
      expect(result.center, const Point<double>(0.9, 0.9));
      expect(result.isFreePosition, isFalse);
    });

    test('without freeCenter uses first grid position', () {
      final config = CharacterConfig.fromEmpty()
        ..positions = [const Point<int>(3, 3)]
        ..freeCenter = null;

      final result = config.getPrompt();
      expect(result.center, const Point<double>(0.5, 0.5));
      expect(result.isFreePosition, isFalse);
    });
  });
}
