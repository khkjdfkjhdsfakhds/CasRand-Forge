import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';

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
  });
}
