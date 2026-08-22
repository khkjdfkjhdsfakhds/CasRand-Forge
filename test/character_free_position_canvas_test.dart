import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_free_position_canvas.dart';

Widget _wrap(CharacterFreePositionCanvas canvas) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: SizedBox(width: 300, height: 500, child: canvas)),
    ),
  );
}

CharacterConfigViewmodel _vm({bool isV5 = true}) {
  return CharacterConfigViewmodel(
    config: CharacterConfig.fromEmpty(),
    paramConfig: ParamConfig(
      model: isV5 ? 'nai-diffusion-5-full' : 'nai-diffusion-4-5-full',
      autoPosition: false,
      sizes: const [GenerationSize(height: 1216, width: 832)],
    ),
  );
}

void main() {
  group('CharacterFreePositionCanvas', () {
    testWidgets('keeps the aspect ratio of the first generation size',
        (tester) async {
      final vm = _vm();
      await tester
          .pumpWidget(_wrap(CharacterFreePositionCanvas(viewmodel: vm)));

      final aspect = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(aspect.aspectRatio, closeTo(832 / 1216, 0.0001));
      expect(find.text('832 × 1216'), findsOneWidget);
    });

    testWidgets('drag updates the V5 free center in normalized coordinates',
        (tester) async {
      final vm = _vm();
      vm.setFreeCenter(const Point<double>(0.5, 0.5));
      await tester
          .pumpWidget(_wrap(CharacterFreePositionCanvas(viewmodel: vm)));

      final rect =
          tester.getRect(find.byKey(const Key('character-free-canvas')));
      final gesture = await tester.startGesture(rect.topLeft);
      await gesture
          .moveTo(rect.topLeft + Offset(rect.width * 0.25, rect.height * 0.5));
      await gesture.up();
      await tester.pump();

      expect(vm.config.freeCenter!.x, closeTo(0.25, 0.02));
      expect(vm.config.freeCenter!.y, closeTo(0.5, 0.02));
      expect(vm.config.positions, isEmpty);
    });

    testWidgets('shows the character label on the editable point',
        (tester) async {
      final vm = _vm();
      vm.setFreeCenter(const Point<double>(0.5, 0.5));
      await tester.pumpWidget(_wrap(
        CharacterFreePositionCanvas(viewmodel: vm, characterLabel: 'Alice'),
      ));

      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('labels every character point, and skips unplaced ones',
        (tester) async {
      final vm = _vm();
      vm.setFreeCenter(const Point<double>(0.5, 0.5));
      await tester.pumpWidget(_wrap(CharacterFreePositionCanvas(
        viewmodel: vm,
        characterIndex: 1,
        referencePositions: const <Point<double>?>[
          Point<double>(0.2, 0.3),
          null,
          Point<double>(0.8, 0.8),
        ],
      )));

      // Characters 1 and 3 show reference labels; the middle (unplaced)
      // is skipped; the edited character 2 shows its point with '2'.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });
  });
}
