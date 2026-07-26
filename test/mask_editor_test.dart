import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/mask_editor_view.dart';

void main() {
  testWidgets('brush strokes rasterize to white on black at image size', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
              isErase: false,
              brushSize: 40,
              points: [Offset(100, 100), Offset(300, 100)],
            ),
          ],
          imageWidth: 400,
          imageHeight: 200,
        ));

    final mask = img.decodePng(bytes!)!;
    expect(mask.width, 400);
    expect(mask.height, 200);
    // On the stroke: white.
    expect(mask.getPixel(200, 100).r, greaterThan(200));
    // Far from the stroke: black.
    expect(mask.getPixel(20, 180).r, lessThan(50));
    // Just outside the brush radius (20px): still black.
    expect(mask.getPixel(200, 160).r, lessThan(50));
  });

  testWidgets('a single point paints a filled dot', (tester) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
                isErase: false, brushSize: 60, points: [Offset(100, 100)]),
          ],
          imageWidth: 200,
          imageHeight: 200,
        ));

    final mask = img.decodePng(bytes!)!;
    expect(mask.getPixel(100, 100).r, greaterThan(200));
    expect(mask.getPixel(120, 100).r, greaterThan(200));
    expect(mask.getPixel(180, 180).r, lessThan(50));
  });

  testWidgets('erase strokes cut back into earlier brush strokes', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
              isErase: false,
              brushSize: 100,
              points: [Offset(100, 100), Offset(300, 100)],
            ),
            MaskStroke(
              isErase: true,
              brushSize: 60,
              points: [Offset(200, 100)],
            ),
          ],
          imageWidth: 400,
          imageHeight: 200,
        ));

    final mask = img.decodePng(bytes!)!;
    // Erased center is black again.
    expect(mask.getPixel(200, 100).r, lessThan(50));
    // The rest of the brush stroke survives.
    expect(mask.getPixel(120, 100).r, greaterThan(200));
    expect(mask.getPixel(280, 100).r, greaterThan(200));
  });

  testWidgets('strokes stay in image space regardless of aspect', (
    tester,
  ) async {
    final bytes = await tester.runAsync(() => rasterizeMaskStrokes(
          strokes: const [
            MaskStroke(
                isErase: false, brushSize: 20, points: [Offset(700, 1100)]),
          ],
          imageWidth: 1600,
          imageHeight: 2400,
        ));

    final mask = img.decodePng(bytes!)!;
    expect(mask.width, 1600);
    expect(mask.height, 2400);
    expect(mask.getPixel(700, 1100).r, greaterThan(200));
    expect(mask.getPixel(700, 1200).r, lessThan(50));
  });
}
