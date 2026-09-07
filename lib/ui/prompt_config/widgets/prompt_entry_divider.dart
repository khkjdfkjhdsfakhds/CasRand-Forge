import 'package:flutter/material.dart';

Color promptEntryDividerColor(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant.withAlpha(128);

class PromptEntryDivider extends StatelessWidget {
  const PromptEntryDivider({super.key, required this.color});

  static const height = 10.0;

  // Font line metrics absorb part of the added leading. An extra 22px on
  // the first glyph after a boundary leaves the same ~8px per side as preview.
  static const editorBoundaryExtraLeading = 22.0;

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: PromptEntryDividerPainter(color),
      ),
    );
  }
}

class PromptEntryDividerPainter extends CustomPainter {
  const PromptEntryDividerPainter(
    this.color, {
    this.verticalOffset = 0,
  });

  static const dashWidth = 8.0;
  static const gapWidth = 2.0;
  static const strokeWidth = 1.0;

  final Color color;
  final double verticalOffset;

  double lineY(Size size) => (size.height / 2 + verticalOffset)
      .clamp(strokeWidth / 2, size.height - strokeWidth / 2)
      .toDouble();

  static void paintDashedLine(
    Canvas canvas, {
    required double startX,
    required double endX,
    required double y,
    required Color color,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    for (var x = startX; x < endX; x += dashWidth + gapWidth) {
      final dashEnd = (x + dashWidth).clamp(startX, endX);
      canvas.drawLine(Offset(x, y), Offset(dashEnd, y), paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    paintDashedLine(
      canvas,
      startX: 0,
      endX: size.width,
      y: lineY(size),
      color: color,
    );
  }

  @override
  bool shouldRepaint(PromptEntryDividerPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.verticalOffset != verticalOffset;
  }

  @override
  bool hitTest(Offset position) => false;
}
