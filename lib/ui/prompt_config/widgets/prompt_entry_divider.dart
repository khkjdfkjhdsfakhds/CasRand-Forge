import 'package:flutter/material.dart';

Color promptEntryDividerColor(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant.withAlpha(128);

class PromptEntryDivider extends StatelessWidget {
  const PromptEntryDivider({super.key, required this.color});

  static const height = 10.0;

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
  const PromptEntryDividerPainter(this.color);

  static const dashWidth = 8.0;
  static const gapWidth = 2.0;
  static const strokeWidth = 1.0;

  final Color color;

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
      y: size.height / 2,
      color: color,
    );
  }

  @override
  bool shouldRepaint(PromptEntryDividerPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
