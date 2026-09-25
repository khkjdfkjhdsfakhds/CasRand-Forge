import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/scribble_document.dart';
import 'package:nai_casrand/ui/i2i_page/widgets/scribble_editor_view.dart';

Uint8List _png(img.Image image) => Uint8List.fromList(img.encodePng(image));

void main() {
  test('renders colored strokes and erases only the drawing layer', () async {
    final source = img.Image(width: 32, height: 24, numChannels: 3);
    img.fill(source, color: img.ColorRgb8(20, 40, 60));
    final document = ScribbleDocument(
      originalBytes: _png(source),
      width: 32,
      height: 24,
      strokes: [
        ScribbleStroke(
          points: const [ui.Offset(8, 8), ui.Offset(16, 8)],
          color: const ui.Color(0xffff0000),
          width: 4,
        ),
        ScribbleStroke(
          points: const [ui.Offset(12, 8)],
          color: const ui.Color(0x00000000),
          width: 4,
          erase: true,
        ),
      ],
    );
    final output = img.decodePng(await renderScribbleDocument(document))!;
    expect(output.getPixel(8, 8).r, greaterThan(200));
    expect(output.getPixel(12, 8).r, lessThan(100));
    expect(output.getPixel(12, 8).g, lessThan(100));
    expect(output.getPixel(0, 0).b, 60);
  });

  test('an empty document returns the original bytes unchanged', () async {
    final bytes = _png(img.Image(width: 8, height: 6, numChannels: 3));
    final result = await renderScribbleDocument(ScribbleDocument(
      originalBytes: bytes,
      width: 8,
      height: 6,
    ));
    expect(result, same(bytes));
  });
}
