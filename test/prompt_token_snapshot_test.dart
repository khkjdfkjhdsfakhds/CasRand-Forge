import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_token_snapshot.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prompt_tokenizer.dart';
import 'nai5_selected_compatibility_test.dart' show configFor, infill;

void main() {
  test('fixed captions equal actual final captions without mutating settings',
      () {
    for (final model in [
      'nai-diffusion-5-full',
      'nai-diffusion-5-curated',
      'nai-diffusion-4-5-full',
      'nai-diffusion-3'
    ]) {
      final config = configFor(model)..promptMode = PromptMode.fixed;
      config.paramConfig.model = model;
      config.paramConfig.transparentBackground = true;
      config.rootPromptConfig =
          PayloadConfig.fixedPromptConfig('a sign "HELLO"');
      config.negativePromptConfig =
          PayloadConfig.fixedPromptConfig('bad', negative: true);
      config.characterConfigList.addAll([
        CharacterConfig.fromEmpty()
          ..enabled = true
          ..freeCenter = const Point(.244, .541)
          ..positivePromptConfig = PayloadConfig.fixedPromptConfig('girl "ONE"')
          ..negativePromptConfig = PayloadConfig.fixedPromptConfig('bad hands'),
        CharacterConfig.fromEmpty()
          ..enabled = false
          ..positivePromptConfig = PayloadConfig.fixedPromptConfig('ignored'),
      ]);
      final before = jsonEncode(config.toJson());
      final preview = PromptTokenSnapshot.fixed(config)!;
      expect(jsonEncode(config.toJson()), before);
      final actual = PromptTokenSnapshot.fromPayload(
          GeneratePayloadUseCase(payloadConfig: config)().payload);
      expect(preview.model, actual.model);
      expect(preview.positive, actual.positive);
      expect(preview.negative, actual.negative);
      expect(preview.positive.join(), isNot(contains('ignored')));
    }
  });

  test('snapshots use effective fallback model and never duplicate input', () {
    final config = configFor('nai-diffusion-5-curated');
    final payload =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: infill)()
            .payload;
    final snapshot = PromptTokenSnapshot.fromPayload(payload);
    expect(snapshot.model, 'nai-diffusion-4-5-curated-inpainting');
    expect(promptTokenizerFor(snapshot.model), PromptTokenizerKind.t5);
    expect(promptTokenLimit(snapshot.model), 512);
    expect(snapshot.positive, ['a sign']);
  });

  test('random/sequence projection never consumes a candidate', () {
    final config = configFor('nai-diffusion-5-full');
    config.rootPromptConfig.selectionMethod = 'single_sequential';
    config.rootPromptConfig.strs = ['first', 'second'];
    final store = PromptTokenSnapshots();
    for (var i = 0; i < 20; i++) {
      expect(PromptTokenSnapshot.fixed(config), isNull);
      expect(store.latest(config), isNull);
    }
    final ticket = store.begin(config);
    final payload = GeneratePayloadUseCase(payloadConfig: config)().payload;
    store.record(config, ticket, payload);
    expect(store.latest(config)!.positive, ['first']);
    for (var i = 0; i < 20; i++) {
      store.latest(config);
    }
    expect(GeneratePayloadUseCase(payloadConfig: config)().payload['input'],
        'second');
    store.dispose();
  });

  test('late tasks cannot replace newer snapshot or cross model/profile/tool',
      () {
    final config = configFor('nai-diffusion-5-full');
    final store = PromptTokenSnapshots();
    final old = store.begin(config), current = store.begin(config);
    final payload = GeneratePayloadUseCase(payloadConfig: config)().payload;
    store.record(config, current, payload);
    final newer = store.latest(config);
    store.record(config, old, {...payload, 'input': 'old'});
    expect(identical(newer, store.latest(config)), isTrue);
    config.paramConfig.model = 'nai-diffusion-5-curated';
    expect(store.latest(config), isNull);
    store.record(config, old, payload);
    expect(store.latest(config), isNull);
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.randomProfile = config.randomProfile.copy();
    expect(store.latest(config), isNull);
    store.dispose();
  });

  test(
      'fixed character comments match request and complex sources wait for task',
      () {
    final config = configFor('nai-diffusion-5-full')
      ..promptMode = PromptMode.fixed;
    final character = CharacterConfig.fromEmpty()
      ..enabled = true
      ..positivePromptConfig =
          PayloadConfig.fixedPromptConfig('# local comment\ngirl')
      ..negativePromptConfig =
          PayloadConfig.fixedPromptConfig('# local comment\nbad');
    config.characterConfigList.add(character);
    final preview = PromptTokenSnapshot.fixed(config)!;
    final actual = PromptTokenSnapshot.fromPayload(
        GeneratePayloadUseCase(payloadConfig: config)().payload);
    expect(preview.positive, actual.positive);
    expect(preview.negative, actual.negative);
    expect(preview.positive.last, 'girl');
    config.rootPromptConfig.randomBracketsUpper = 1;
    expect(PromptTokenSnapshot.fixed(config), isNull);
    config.rootPromptConfig.randomBracketsUpper = 0;
    config.rootPromptConfig.selectionMethod = 'multiple_prob';
    expect(PromptTokenSnapshot.fixed(config), isNull);
    config.rootPromptConfig = PayloadConfig.fixedPromptConfig('__saved__');
    config.savedPromptConfigList
        .add(PayloadConfig.fixedPromptConfig('expanded')..comment = 'saved');
    expect(PromptTokenSnapshot.fixed(config), isNull);
  });

  test(
      'display chunks preserve empties and six-chunk limit, alternatives use last longest',
      () {
    expect(PromptTokenDisplay.chunks('red|blue'), ['red', 'blue']);
    expect(PromptTokenDisplay.chunks('||red|blue hair||'), ['blue hair']);
    expect(PromptTokenDisplay.chunks('x||red|cat||y'), ['xcaty']);
    expect(PromptTokenDisplay.chunks('||red|blue hair'), ['blue hair']);
    expect(PromptTokenDisplay.chunks('|a||'), ['', 'a']);
    expect(PromptTokenDisplay.chunks('a|b|c|d|e|f|g'),
        ['a', 'b', 'c', 'd', 'e', 'f|g']);
    expect(PromptTokenDisplay.chunks(''), ['']);
  });

  test('model token limits keep positive and negative budgets independent', () {
    expect(promptTokenLimit('nai-diffusion-5-full'), 1471);
    expect(promptTokenLimit('nai-diffusion-5-curated'), 703);
    expect(promptTokenLimit('nai-diffusion-4-full'), 512);
    expect(promptTokenLimit('nai-diffusion-3'), 225);
  });
}
