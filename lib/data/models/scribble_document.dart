import 'dart:typed_data';
import 'dart:ui';

/// Session-only artwork: keeping the original separate lets the eraser reveal
/// it even after closing and reopening the editor.
class ScribbleDocument {
  final Uint8List originalBytes;
  final int width;
  final int height;
  final List<ScribbleStroke> strokes;

  ScribbleDocument({
    required this.originalBytes,
    required this.width,
    required this.height,
    Iterable<ScribbleStroke> strokes = const [],
  }) : strokes = List.unmodifiable(strokes);
}

class ScribbleStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool erase;

  ScribbleStroke({
    required Iterable<Offset> points,
    required this.color,
    required this.width,
    this.erase = false,
  }) : points = List.unmodifiable(points);
}
