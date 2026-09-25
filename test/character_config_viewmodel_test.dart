import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';

void main() {
  group('V5 free-position viewmodel', () {
    test('setFreeCenter writes a normalized Point<double>', () {
      final config = CharacterConfig.fromEmpty();
      final vm = CharacterConfigViewmodel(
        config: config,
        paramConfig: ParamConfig(autoPosition: false),
      );

      vm.setFreeCenter(const Point<double>(0.244, 0.541));

      expect(config.freeCenter, const Point<double>(0.244, 0.541));
      expect(config.rememberedFreeCenter, const Point<double>(0.244, 0.541));
    });

    test('isV5 is true for diffusion-5 model ids', () {
      final vm = CharacterConfigViewmodel(
        config: CharacterConfig.fromEmpty(),
        paramConfig: ParamConfig(model: 'nai-diffusion-5-full'),
      );
      expect(vm.isV5, isTrue);

      final vm45 = CharacterConfigViewmodel(
        config: CharacterConfig.fromEmpty(),
        paramConfig: ParamConfig(model: 'nai-diffusion-4-5-full'),
      );
      expect(vm45.isV5, isFalse);
    });

    test('firstGenerationSize returns first configured size', () {
      final vm = CharacterConfigViewmodel(
        config: CharacterConfig.fromEmpty(),
        paramConfig: ParamConfig(
          sizes: const [
            GenerationSize(height: 1216, width: 832),
            GenerationSize(height: 1024, width: 1024),
          ],
        ),
      );
      expect(vm.firstGenerationSize,
          const GenerationSize(height: 1216, width: 832));
    });

    test('getPositionsTexts shows continuous x/y for a V5 free center', () {
      final vm = CharacterConfigViewmodel(
        config: CharacterConfig.fromEmpty(),
        paramConfig: ParamConfig(
          model: 'nai-diffusion-5-full',
          autoPosition: false,
        ),
      );
      vm.setFreeCenter(const Point<double>(0.244, 0.541));

      expect(vm.getPositionsTexts(), 'x:0.244, y:0.541');
    });

    test('AI choice preserves an explicit free center for later manual use', () {
      final config = CharacterConfig.fromEmpty()
        ..freeCenter = const Point<double>(0.244, 0.541);
      final vm = CharacterConfigViewmodel(
        config: config,
        paramConfig: ParamConfig(
          model: 'nai-diffusion-5-full',
          autoPosition: false,
        ),
      );

      vm.setAutoPosition(true);

      expect(config.freeCenter, isNull);
      expect(config.rememberedFreeCenter, const Point<double>(0.244, 0.541));
      expect(vm.autoPosition, isTrue);

      vm.setAutoPosition(false);

      expect(config.freeCenter, const Point<double>(0.244, 0.541));
    });

    test('manual grid click forgets the remembered V5 center', () {
      final config = CharacterConfig.fromEmpty()
        ..freeCenter = const Point<double>(0.244, 0.541)
        ..rememberedFreeCenter = const Point<double>(0.244, 0.541);
      final vm = CharacterConfigViewmodel(
        config: config,
        paramConfig: ParamConfig(
          model: 'nai-diffusion-5-full',
          autoPosition: false,
        ),
      );

      vm.switchPosition(const Point<int>(1, 5));

      expect(config.freeCenter, isNull);
      expect(config.rememberedFreeCenter, isNull);
      expect(config.positions, [const Point<int>(1, 5)]);
    });

    test('manual choice without history still falls back to C3', () {
      final config = CharacterConfig.fromEmpty()
        ..positions = []
        ..freeCenter = null;
      final vm = CharacterConfigViewmodel(
        config: config,
        paramConfig: ParamConfig(
          model: 'nai-diffusion-5-full',
          autoPosition: true,
        ),
      );

      vm.setAutoPosition(false);

      expect(config.positions, [CharacterConfig.defaultPosition]);
    });
  });

  group('payload-wide auto position', () {
    PromptTabViewmodel build(List<CharacterConfig> characters) {
      PromptConfig empty() => PromptConfig(
            shuffled: false,
            comment: '',
            strs: [],
            prompts: [],
          );
      return PromptTabViewmodel(
        promptConfig: empty(),
        negativePromptConfig: empty(),
        characterConfigList: characters,
        savedConfigList: [],
        paramConfig: ParamConfig(
          model: 'nai-diffusion-5-full',
          autoPosition: false,
        ),
      );
    }

    test('AI choice then manual restores every character center', () {
      final first = CharacterConfig.fromEmpty()
        ..freeCenter = const Point<double>(0.2, 0.3)
        ..rememberedFreeCenter = const Point<double>(0.2, 0.3);
      final second = CharacterConfig.fromEmpty()
        ..freeCenter = const Point<double>(0.8, 0.9)
        ..rememberedFreeCenter = const Point<double>(0.8, 0.9);
      final vm = build([first, second]);

      vm.setAutoPosition(true);

      expect(first.freeCenter, isNull);
      expect(second.freeCenter, isNull);

      vm.setAutoPosition(false);

      expect(first.freeCenter, const Point<double>(0.2, 0.3));
      expect(second.freeCenter, const Point<double>(0.8, 0.9));

      // The restored point, not the leftover C3 fallback, is what the card
      // and the payload use.
      final firstView = CharacterConfigViewmodel(
        config: first,
        paramConfig: vm.paramConfig,
      );
      expect(firstView.getPositionsTexts(), 'x:0.200, y:0.300');
      expect(first.getPrompt().center, const Point<double>(0.2, 0.3));
      expect(first.getPrompt().isFreePosition, isTrue);
    });

    test('characters without saved history fall back to C3', () {
      final character = CharacterConfig.fromEmpty()
        ..positions = []
        ..freeCenter = null;
      final vm = build([character]);

      vm.setAutoPosition(true);
      vm.setAutoPosition(false);

      expect(character.freeCenter, isNull);
      expect(character.positions, [CharacterConfig.defaultPosition]);
    });
  });
}
