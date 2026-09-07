import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

PromptConfig _prompt(String text) => PromptConfig(
      shuffled: false,
      strs: [text],
      prompts: [],
    );

CharacterConfig _character(String text,
        {Point<double>? center, bool enabled = true}) =>
    CharacterConfig(
      positions: [CharacterConfig.defaultPosition],
      freeCenter: center,
      positivePromptConfig: _prompt(text),
      negativePromptConfig: _prompt('avoid "NEGATIVE"'),
      gender: '',
      enabled: enabled,
    );

PayloadConfig _config(
  String base, {
  String model = 'nai-diffusion-5-full',
  List<CharacterConfig> characters = const [],
  bool fixed = false,
}) =>
    PayloadConfig(
      rootPromptConfig: _prompt(base),
      negativePromptConfig: _prompt('avoid "NEGATIVE"'),
      characterConfigList: characters,
      savedPromptConfigList: [],
      paramConfig: ParamConfig(model: model),
      settings: Settings.fromJson({}),
      overridePrompt: base,
      useOverridePrompt: fixed,
      useCharacterPromptWithOverride: true,
    );

String _input(PayloadConfig config, {String suffix = ''}) {
  final payload =
      GeneratePayloadUseCase(payloadConfig: config, promptSuffix: suffix)()
          .payload;
  final input = payload['input'] as String;
  expect(payload['parameters']['v4_prompt']['caption']['base_caption'], input);
  return input;
}

void main() {
  test('V5 character dialogue reaches base text block without changing config',
      () {
    final config = _config('portrait',
        characters: [_character('speech bubble, text"你好"')]);
    final before = jsonEncode(config.toJson());
    expect(_input(config), 'portrait, teXt: 你好');
    expect(jsonEncode(config.toJson()), before);
    expect(_input(config), 'portrait, teXt: 你好');
  });

  test('fixed V5 base quotes are processed after suffix and transparency', () {
    final config = _config('sign "Hello"', fixed: true);
    config.paramConfig.transparentBackground = true;
    expect(_input(config, suffix: 'crisp lines'),
        'sign "Hello", crisp lines, transparent background, teXt: Hello');
  });

  test('manual text block is not duplicated including metadata round trips',
      () {
    for (final marker in ['Text:', 'text:', 'teXt:', 'TEXT:']) {
      final base = 'sign "Hello", $marker Manual';
      expect(_input(_config(base)), base);
    }
    const base = 'portrait, teXt: 你好';
    expect(_input(_config(base, characters: [_character('text"你好"')])), base);
  });

  test('manual character text block disables automatic extraction', () {
    expect(
        _input(
            _config('sign "Base"', characters: [_character('Text: Manual')])),
        'sign "Base"');
  });

  test('unquoted prompts and older models retain exact input', () {
    expect(_input(_config('plain portrait')), 'plain portrait');
    for (final model in [
      'nai-diffusion-3',
      'nai-diffusion-4-full',
      'nai-diffusion-4-5-full'
    ]) {
      expect(_input(_config('sign "Hello"', model: model)), 'sign "Hello"');
    }
  });

  test('inactive characters and negative prompts never become rendered text',
      () {
    final config =
        _config('portrait', characters: [_character('"OFF"', enabled: false)]);
    expect(_input(config), 'portrait');
  });

  test('English quoted pieces retain order with blank line separators', () {
    expect(
        _input(_config('"First" and “Second”',
            characters: [_character('「Third」')])),
        '"First" and “Second”, teXt: First\n\nSecond\n\nThird');
  });

  test('CJK reverses quoted pieces within each prompt like the website', () {
    expect(_input(_config('“甲” and “乙”', characters: [_character('「丙」「丁」')])),
        '“甲” and “乙”, teXt: 乙\n\n甲\n\n丁\n\n丙');
  });

  test('apostrophes inside words are not dialogue boundaries', () {
    expect(_input(_config("girl's hat, don't change")),
        "girl's hat, don't change");
    expect(_input(_config("sign 'It's fine' and ‘Don't worry’")),
        "sign 'It's fine' and ‘Don't worry’, teXt: It's fine\n\nDon't worry");
  });

  test('empty and unclosed quotes do not append text', () {
    for (final base in ['sign ""', 'sign “  ”', 'sign "Unclosed']) {
      expect(_input(_config(base)), base);
    }
  });

  test('weight syntax named text is not mistaken for manual text block', () {
    expect(_input(_config('1.2::text::, "Hello"')),
        '1.2::text::, "Hello", teXt: Hello');
  });

  test(
      'positioned characters use website row ordering without reordering captions',
      () {
    final chars = [
      _character('"Bottom"', center: const Point(.1, .8)),
      _character('"Right"', center: const Point(.9, .1)),
      _character('"Left"', center: const Point(.1, .15)),
    ];
    final config = _config('portrait', characters: chars);
    final payload = GeneratePayloadUseCase(payloadConfig: config)().payload;
    expect(payload['input'], 'portrait, teXt: Left\n\nRight\n\nBottom');
    expect(payload['parameters']['characterPrompts'][0]['prompt'], '"Bottom"');
  });

  test('automatic positioning preserves character list order', () {
    expect(
        _input(_config('portrait',
            characters: [_character('"B"'), _character('"A"')])),
        'portrait, teXt: B\n\nA');
  });

  test('prompt chunks retain separators and only extract base chunk quotes',
      () {
    expect(_input(_config('"Base" | "Later"')), '"Base", teXt: Base| "Later"');
    expect(_input(_config('"A || B | C||" | later')),
        '"A || B | C||", teXt: A || B | C||| later');
  });

  test('random sequential choices are consumed once per request', () {
    final config = _config('');
    config.rootPromptConfig = PromptConfig(
      selectionMethod: 'single_sequential',
      shuffled: false,
      strs: ['"First"', '"Second"'],
      prompts: [],
    );
    expect(_input(config), '"First", teXt: First');
    expect(_input(config), '"Second", teXt: Second');
  });

  test('fixed V5 Curated character dialogue is processed too', () {
    final config = _config('portrait',
        fixed: true,
        model: 'nai-diffusion-5-curated',
        characters: [_character('speech bubble "Hello"')]);
    expect(_input(config), 'portrait, teXt: Hello');
  });

  for (final inpaint in [false, true]) {
    test('text conditioning survives I2I plan and frozen tiles: $inpaint', () {
      final plan = I2iRequestPlan(
        imageB64: 'offline-image',
        maskB64: inpaint ? 'offline-mask' : null,
        width: 1024,
        height: 1024,
        strength: .7,
        noise: .2,
        addOriginalImage: false,
        composite: null,
        summary: 'offline fixture',
      );
      final config = _config('sign "Hello"');
      final payload = GeneratePayloadUseCase(
        payloadConfig: config,
        i2iPlan: plan,
        seedOverride: 42,
        promptSuffix: 'crisp lines',
      )()
          .payload;
      expect(payload['input'], 'sign "Hello", crisp lines, teXt: Hello');
      expect(payload['action'], inpaint ? 'infill' : 'img2img');
      final tiled = GeneratePayloadUseCase.applyI2iPlanToPayload(payload, plan);
      expect(tiled['input'], payload['input']);
      expect(
          tiled['parameters']['v4_prompt'], payload['parameters']['v4_prompt']);
      expect(tiled['parameters']['seed'], 42);
    });
  }
}
