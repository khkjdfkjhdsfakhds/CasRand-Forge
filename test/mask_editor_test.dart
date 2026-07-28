import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/mask_editor_view.dart';

void main() {
  test('official pixel-circle footprints match the production editor', () {
    expect(officialMaskCircleCells(1), hasLength(1));
    expect(officialMaskCircleCells(2), hasLength(4));
    expect(officialMaskCircleCells(3), hasLength(5));
    expect(officialMaskCircleCells(4), hasLength(21));
    expect(officialMaskCircleCells(26), hasLength(593));
    expect(officialMaskCircleCells(50), hasLength(2077));

    final size4Rows = <int, int>{};
    for (final cell in officialMaskCircleCells(4)) {
      size4Rows.update(cell.y, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(size4Rows.values.toList(), [3, 5, 5, 5, 3]);
  });

  test('sizes 4-50 match NovelAI drawPixelCircle corner tests', () {
    for (var size = 4; size <= 50; size++) {
      final radius = (size / 2).round();
      final expected = <math.Point<int>>{};
      for (var y = -radius; y <= radius; y++) {
        for (var x = -radius; x <= radius; x++) {
          final outer = math.sqrt(
            (x.abs() + 0.5) * (x.abs() + 0.5) +
                (y.abs() + 0.5) * (y.abs() + 0.5),
          );
          final inner = math.sqrt(
            (x.abs() - 0.5) * (x.abs() - 0.5) +
                (y.abs() - 0.5) * (y.abs() - 0.5),
          );
          if (math.min(outer, inner) <= radius) {
            expected.add(math.Point(x, y));
          }
        }
      }
      expect(officialMaskCircleCells(size).toSet(), expected, reason: '$size');
    }
  });

  testWidgets('official size-4 circle rasterizes as 21 full mask cells', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
              isErase: false,
              brushSize: 4,
              points: [Offset(256, 256)],
            ),
          ],
          imageWidth: 512,
          imageHeight: 512,
        ));

    final mask = img.decodePng(bytes!)!;
    var whitePixels = 0;
    for (final pixel in mask) {
      if (pixel.r > 200) whitePixels++;
    }
    expect(whitePixels, 21 * latentGrid * latentGrid);
    expect(mask.getPixel(256, 240).r, greaterThan(200));
    expect(mask.getPixel(272, 240).r, lessThan(50));
  });

  testWidgets('size-1 brush interpolates quickly dragged paths without gaps', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
              isErase: false,
              brushSize: 1,
              points: [Offset(64, 64), Offset(400, 64)],
            ),
          ],
          imageWidth: 464,
          imageHeight: 128,
        ));

    final mask = img.decodePng(bytes!)!;
    for (var x = 68; x <= 404; x += latentGrid) {
      expect(
        mask.getPixel(x, 68).r,
        greaterThan(200),
        reason: 'mask cell centered at x=$x should be connected',
      );
    }
    expect(mask.getPixel(68, 84).r, lessThan(50));
  });

  testWidgets('size-2 square brush paints exactly two by two mask cells', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
              isErase: false,
              brushSize: 2,
              shape: MaskBrushShape.square,
              points: [Offset(100, 100)],
            ),
          ],
          imageWidth: 200,
          imageHeight: 200,
        ));

    final mask = img.decodePng(bytes!)!;
    var whitePixels = 0;
    for (final pixel in mask) {
      if (pixel.r > 200) whitePixels++;
    }
    expect(whitePixels, 4 * latentGrid * latentGrid);
  });

  testWidgets('size-3 eraser uses the same five-cell cross footprint', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
              isErase: false,
              brushSize: 26,
              points: [Offset(256, 256)],
            ),
            MaskStroke(
              isErase: true,
              brushSize: 3,
              points: [Offset(256, 256)],
            ),
          ],
          imageWidth: 512,
          imageHeight: 512,
        ));

    final mask = img.decodePng(bytes!)!;
    expect(mask.getPixel(260, 260).r, lessThan(50));
    expect(mask.getPixel(268, 260).r, lessThan(50));
    expect(mask.getPixel(268, 268).r, greaterThan(200));
  });

  testWidgets('strokes stay in image space regardless of aspect', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
                isErase: false, brushSize: 1, points: [Offset(700, 1100)]),
          ],
          imageWidth: 1600,
          imageHeight: 2400,
        ));

    final mask = img.decodePng(bytes!)!;
    expect(mask.width, 1600);
    expect(mask.height, 2400);
    expect(mask.getPixel(700, 1100).r, greaterThan(200));
    expect(mask.getPixel(700, 1120).r, lessThan(50));
  });

  testWidgets('saving a Focus frame does not require painting a mask', (
    tester,
  ) async {
    final image = img.Image(width: 320, height: 240, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(80, 100, 120));
    final imageBytes = Uint8List.fromList(img.encodePng(image));
    MaskEditorResult? saved;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const Key('open-editor'),
            onPressed: () async {
              saved = await MaskEditorView.open(
                context,
                imageBytes: imageBytes,
                imageWidth: 320,
                imageHeight: 240,
                initialStrokes: const [],
                initialFocusFrame: const CropRect(
                  x: 40,
                  y: 32,
                  w: 160,
                  h: 128,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-editor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mask-editor-done')));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.maskBytes, isNull);
    expect(saved!.focusFrame, const CropRect(x: 40, y: 32, w: 160, h: 128));
  });

  testWidgets('Square Brush control changes the shape stored on a stroke', (
    tester,
  ) async {
    final image = img.Image(width: 320, height: 240, numChannels: 3);
    MaskEditorResult? saved;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => FilledButton(
          key: const Key('open-editor'),
          onPressed: () async {
            saved = await MaskEditorView.open(
              context,
              imageBytes: Uint8List.fromList(img.encodePng(image)),
              imageWidth: 320,
              imageHeight: 240,
              initialStrokes: const [],
            );
          },
          child: const Text('Open'),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open-editor')));
    await tester.pumpAndSettle();

    final brushSlider = tester.widget<Slider>(
      find.byKey(const Key('mask-editor-brush-size')),
    );
    expect(brushSlider.min, 1);
    expect(brushSlider.max, 50);
    expect(brushSlider.value, 4);
    expect(brushSlider.divisions, 49);

    final checkbox = find.byKey(const Key('mask-editor-square-brush'));
    expect(checkbox, findsOneWidget);
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);
    await tester.tap(checkbox);
    await tester.pump();
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);

    final canvas = find.byKey(const Key('mask-editor-canvas'));
    await tester.dragFrom(tester.getCenter(canvas), const Offset(20, 0));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mask-editor-undo')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mask-editor-redo')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('mask-editor-done')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.strokes, hasLength(1));
    expect(saved!.strokes.single.shape, MaskBrushShape.square);
  });

  testWidgets('brush controls fit a phone-size editor without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final image = img.Image(width: 320, height: 480, numChannels: 3);

    await tester.pumpWidget(MaterialApp(
      home: MaskEditorView(
        imageBytes: Uint8List.fromList(img.encodePng(image)),
        imageWidth: 320,
        imageHeight: 480,
        initialStrokes: const [],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mask-editor-square-brush')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Command-V and Control-V are bound to clipboard mask import', (
    tester,
  ) async {
    final image = img.Image(width: 320, height: 240, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(80, 100, 120));
    final imageBytes = Uint8List.fromList(img.encodePng(image));
    final clipboardMask = img.Image(width: 320, height: 240, numChannels: 3);
    img.fillRect(
      clipboardMask,
      x1: 80,
      y1: 60,
      x2: 160,
      y2: 120,
      color: img.ColorRgb8(255, 255, 255),
    );
    var clipboardReads = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MaskEditorView(
          imageBytes: imageBytes,
          imageWidth: 320,
          imageHeight: 240,
          initialStrokes: const [],
          clipboardImageReader: () async {
            clipboardReads++;
            return Uint8List.fromList(img.encodePng(clipboardMask));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final shortcuts = tester.widget<CallbackShortcuts>(
      find.byType(CallbackShortcuts),
    );
    expect(
      shortcuts.bindings,
      contains(
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true),
      ),
    );
    expect(
      shortcuts.bindings,
      contains(
        const SingleActivator(LogicalKeyboardKey.keyV, control: true),
      ),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    expect(clipboardReads, 1);
    expect(find.byKey(const Key('mask-import-channel')), findsOneWidget);
  });

  testWidgets('invalid clipboard content leaves the mask editor unchanged', (
    tester,
  ) async {
    final image = img.Image(width: 320, height: 240, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(80, 100, 120));

    await tester.pumpWidget(
      MaterialApp(
        home: MaskEditorView(
          imageBytes: Uint8List.fromList(img.encodePng(image)),
          imageWidth: 320,
          imageHeight: 240,
          initialStrokes: const [],
          clipboardImageReader: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mask-import-channel')), findsNothing);
    expect(find.text('mask_import_clipboard_no_image'), findsOneWidget);
    expect(find.byKey(const Key('mask-editor-clear')), findsOneWidget);
    final clearButton = tester.widget<IconButton>(
      find.byKey(const Key('mask-editor-clear')),
    );
    expect(clearButton.onPressed, isNull);
  });
}
