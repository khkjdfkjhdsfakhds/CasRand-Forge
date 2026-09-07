import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_config_view.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';
import 'nai5_selected_compatibility_test.dart' show configFor;

I2iRequestPlan focus(
        {required CropRect outer,
        int width = 1024,
        int height = 1024,
        int contentWidth = 1024,
        int contentHeight = 1024,
        int offsetX = 0,
        int offsetY = 0}) =>
    I2iRequestPlan(
        imageB64: 'image',
        maskB64: 'mask',
        width: width,
        height: height,
        strength: .8,
        noise: .2,
        addOriginalImage: false,
        composite: AutocropCompositeInfo(
            outer: outer,
            sourceWidth: 512,
            sourceHeight: 512,
            contentOffsetX: offsetX,
            contentOffsetY: offsetY,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            scale: 4),
        summary: 'focus');

void expectCenter(Map<String, dynamic> payload, double x, double y,
    {int index = 0}) {
  final parameters = payload['parameters'];
  final centers = [
    parameters['characterPrompts'][index]['center'],
    parameters['v4_prompt']['caption']['char_captions'][index]['centers'][0],
    parameters['v4_negative_prompt']['caption']['char_captions'][index]
        ['centers'][0]
  ];
  for (final point in centers) {
    expect(point['x'], closeTo(x, 1e-12));
    expect(point['y'], closeTo(y, 1e-12));
  }
}

void main() {
  testWidgets(
      'V4.5 grid highlights B3 for a retained V5 point and selecting it commits that point',
      (tester) async {
    final config = CharacterConfig.fromEmpty()
      ..freeCenter = const Point(.244, .541);
    final parameters =
        ParamConfig(model: 'nai-diffusion-4-5-full', autoPosition: false);
    final vm =
        CharacterConfigViewmodel(config: config, paramConfig: parameters);
    final theme = ThemeData();
    await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(body: CharacterPositionView(viewmodel: vm))));
    final b3 = find.byKey(const Key('character-position-B3'));
    final decoration = tester
        .widget<DecoratedBox>(
            find.descendant(of: b3, matching: find.byType(DecoratedBox)))
        .decoration as BoxDecoration;
    expect(decoration.color, theme.colorScheme.primaryContainer);
    await tester.tap(b3);
    await tester.pump();
    expect(config.freeCenter, isNull);
    expect(config.getPrompt().center, const Point(.3, .5));
    vm.dispose();
  });
  test(
      'Text reading order uses the same clamped coordinates as captions for each tile',
      () {
    final config = configFor('nai-diffusion-5-full');
    config.characterConfigList.addAll([
      CharacterConfig.fromEmpty()
        ..freeCenter = const Point(.4, .5)
        ..positivePromptConfig =
            PayloadConfig.fixedPromptConfig('person "FIRST"'),
      CharacterConfig.fromEmpty()
        ..freeCenter = const Point(.6, .1)
        ..positivePromptConfig =
            PayloadConfig.fixedPromptConfig('person "SECOND"'),
    ]);
    final base = GeneratePayloadUseCase(payloadConfig: config)().payload;
    expect(base['input'], 'a sign, teXt: SECOND\n\nFIRST');
    final plan = focus(outer: const CropRect(x: 400, y: 400, w: 112, h: 112));
    final result = GeneratePayloadUseCase.applyI2iPlanToPayload(base, plan);
    expectCenter(result, 0, 0);
    expectCenter(result, 0, 0, index: 1);
    expect(result['input'], 'a sign, teXt: FIRST\n\nSECOND');
  });

  test(
      'each tile uses original coordinates, includes padding, clamps, and rebuilds Text order',
      () {
    final config = configFor('nai-diffusion-5-full');
    config.paramConfig.autoPosition = false;
    config.characterConfigList.addAll([
      CharacterConfig.fromEmpty()
        ..freeCenter = const Point(.4, .5)
        ..positivePromptConfig =
            PayloadConfig.fixedPromptConfig('person "FIRST"'),
      CharacterConfig.fromEmpty()
        ..freeCenter = const Point(.9, .9)
        ..positivePromptConfig =
            PayloadConfig.fixedPromptConfig('person "LAST"'),
      CharacterConfig.fromEmpty()
        ..enabled = false
        ..freeCenter = const Point(.1, .1)
        ..positivePromptConfig =
            PayloadConfig.fixedPromptConfig('person "DISABLED"'),
    ]);
    final first = focus(outer: const CropRect(x: 128, y: 128, w: 256, h: 256));
    final padded = focus(
        outer: const CropRect(x: 0, y: 0, w: 256, h: 256),
        contentWidth: 768,
        contentHeight: 512,
        offsetX: 128,
        offsetY: 256);
    final original =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: first)().payload;
    expectCenter(original, .3, .5);
    expectCenter(original, 1, 1, index: 1);
    final second =
        GeneratePayloadUseCase.applyI2iPlanToPayload(original, padded);
    expectCenter(second, .725, .75);
    expectCenter(second, 1, 1, index: 1);
    final repeated =
        GeneratePayloadUseCase.applyI2iPlanToPayload(second, first);
    expect(repeated, original);
    expect(second['input'], 'a sign, teXt: FIRST\n\nLAST');
    expect(second['parameters']['v4_prompt']['caption']['base_caption'],
        second['input']);
    expect(second['parameters']['characterPrompts'], hasLength(2));
    expect(config.characterConfigList.first.freeCenter, const Point(.4, .5));
  });
  test(
      'Curated Focus crops original free coordinates before applying V4.5 grid',
      () {
    final config = configFor('nai-diffusion-5-curated');
    config.characterConfigList.add(CharacterConfig.fromEmpty()
      ..freeCenter = const Point(.36, .5)
      ..positivePromptConfig = PayloadConfig.fixedPromptConfig('person'));
    final plan = focus(outer: const CropRect(x: 128, y: 128, w: 256, h: 256));
    final result =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: plan)().payload;
    // .36 -> crop .22 -> grid .3; snapping first would produce .1.
    expectCenter(result, .3, .5);
    expect(GeneratePayloadUseCase.applyI2iPlanToPayload(result, plan), result);
  });
  test('AI positioning and plain generation remain unchanged', () {
    final config = configFor('nai-diffusion-5-full');
    config.characterConfigList.add(CharacterConfig.fromEmpty()
      ..positivePromptConfig = PayloadConfig.fixedPromptConfig('person'));
    final result = GeneratePayloadUseCase(payloadConfig: config)().payload;
    expectCenter(result, .5, .5);
    expect(result['parameters']['v4_prompt']['use_coords'], false);
    final plan = focus(outer: const CropRect(x: 128, y: 128, w: 256, h: 256));
    final tile = GeneratePayloadUseCase.applyI2iPlanToPayload(result, plan);
    expect(tile['parameters']['v4_prompt']['use_coords'], false);
  });
  for (final mode in PromptMode.values) {
    for (final model in ['nai-diffusion-5-full', 'nai-diffusion-5-curated']) {
      test(
          '$mode $model model switch and JSON reopening preserve original point until grid click',
          () async {
        final config = configFor(model)..promptMode = mode;
        config.paramConfig
          ..model = model
          ..autoPosition = false;
        config.characterConfigList.add(CharacterConfig.fromEmpty()
          ..positions = []
          ..freeCenter = const Point(.244, .541)
          ..positivePromptConfig = PayloadConfig.fixedPromptConfig('person'));
        GetIt.I.registerSingleton<PayloadConfig>(config);
        try {
          final parameters = ParametersConfigViewmodel();
          parameters.setModel('nai-diffusion-4-5-full');
          expectCenter(
              GeneratePayloadUseCase(payloadConfig: config)().payload, .3, .5);
          final reopened = PayloadConfig.fromJson(config.toJson());
          expect(reopened.promptMode, mode);
          expectCenter(
              GeneratePayloadUseCase(payloadConfig: reopened)().payload,
              .3,
              .5);
          final restored = reopened.characterConfigList.single;
          expect(restored.effectiveGridPositions, [const Point(2, 3)]);
          expect(restored.freeCenter, const Point(.244, .541));
          final vm = CharacterConfigViewmodel(
              config: restored, paramConfig: config.paramConfig);
          expect(vm.getPositionsTexts(), 'B3');
          parameters.setModel(model);
          expectCenter(GeneratePayloadUseCase(payloadConfig: config)().payload,
              .244, .541);
          parameters.setModel('nai-diffusion-4-5-full');
          vm.switchPosition(const Point(2, 3));
          expect(restored.freeCenter, isNull);
          expect(restored.positions, [const Point(2, 3)]);
          expect(vm.getPositionsTexts(), 'B3');
          // A persisted default C3 must never make clicking C3 ignore a free point.
          restored.freeCenter = const Point(.244, .541);
          restored.positions = [const Point(3, 3)];
          vm.switchPosition(const Point(3, 3));
          expect(restored.freeCenter, isNull);
          expect(restored.getPrompt().center, const Point(.5, .5));
          vm.dispose();
          parameters.dispose();
        } finally {
          await GetIt.I.reset();
        }
      });
    }
  }

  test(
      'Focus derives request coordinates from full image points without mutating saved points',
      () async {
    final source = img.Image(width: 512, height: 512, numChannels: 4);
    final mask = img.Image(width: 512, height: 512, numChannels: 3);
    img.fillRect(mask,
        x1: 200,
        y1: 200,
        x2: 260,
        y2: 260,
        color: img.ColorRgb8(255, 255, 255));
    final input = I2IConfig()
      ..setImage(Uint8List.fromList(img.encodePng(source)));
    input.setMask(Uint8List.fromList(img.encodePng(mask)), [],
        focusFrame: const CropRect(x: 128, y: 128, w: 256, h: 256));
    final plan = (await PrepareI2iRequestUseCase(
        config: input,
        transparentBackground: true)(targetWidth: 512, targetHeight: 512))!;
    final config = configFor('nai-diffusion-5-full');
    final character = CharacterConfig.fromEmpty()
      ..positions = []
      ..freeCenter = const Point(.4, .5)
      ..positivePromptConfig = PayloadConfig.fixedPromptConfig('person');
    config.characterConfigList.add(character);
    final result =
        GeneratePayloadUseCase(payloadConfig: config, i2iPlan: plan)().payload;
    expect(result['parameters']['characterPrompts'][0]['center']['x'],
        closeTo(.3, 1e-12));
    final reapplied =
        GeneratePayloadUseCase.applyI2iPlanToPayload(result, plan);
    expect(reapplied, result);
    expect(character.freeCenter, const Point(.4, .5));
  });

  test(
      'manual V5 to V4.5 switch uses the displayed grid and preserves the free point',
      () {
    final config = configFor('nai-diffusion-5-full');
    config.paramConfig.autoPosition = false;
    final character = CharacterConfig.fromEmpty()
      ..freeCenter = const Point(.244, .541)
      ..positivePromptConfig = PayloadConfig.fixedPromptConfig('person');
    config.characterConfigList.add(character);
    config.paramConfig.model = 'nai-diffusion-4-5-full';
    final result = GeneratePayloadUseCase(payloadConfig: config)().payload;
    expect(result['parameters']['characterPrompts'][0]['center'],
        {'x': .3, 'y': .5});
    final vm = CharacterConfigViewmodel(
        config: character, paramConfig: config.paramConfig);
    expect(vm.getPositionsTexts(), 'B3');
    expect(character.freeCenter, const Point(.244, .541));
    config.paramConfig.model = 'nai-diffusion-5-full';
    expect(
        GeneratePayloadUseCase(payloadConfig: config)().payload['parameters']
            ['characterPrompts'][0]['center'],
        {'x': .244, 'y': .541});
  });
}
