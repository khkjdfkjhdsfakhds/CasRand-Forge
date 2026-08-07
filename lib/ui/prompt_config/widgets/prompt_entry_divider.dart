import 'package:flutter/material.dart';

Color promptEntryDividerColor(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant.withAlpha(128);

class PromptEntryDivider extends StatelessWidget {
  const PromptEntryDivider({super.key, required this.color});

  static const height = 10.0;

  // An inline placeholder forms its own visual line. With the editor's normal
  // line leading, 11px produces the same glyph-to-divider spacing as the 10px
  // standalone preview slot.
  static const inlinePlaceholderHeight = 11.0;

  // Flutter scales WidgetSpan children independently from the surrounding
  // line metrics. This keeps the painted stroke optically centered between
  // the adjacent glyph boxes at both normal and enlarged text scales.
  static double inlineStrokeOffset(double scale) {
    final opticalCorrection = 0.5 + (1.5 * (scale - 1));
    return -opticalCorrection.clamp(0.5, 1.25).toDouble();
  }

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

class PromptEntryDividerPlaceholder extends StatelessWidget {
  const PromptEntryDividerPlaceholder({
    super.key,
    required this.textStyleFontSize,
  });

  final double textStyleFontSize;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final placeholderScale = textScaler.scale(1);
    final bodyScale = textScaler.scale(textStyleFontSize) / textStyleFontSize;
    return SizedBox(
      width: double.infinity,
      height: PromptEntryDivider.inlinePlaceholderHeight / placeholderScale,
      child: CustomPaint(
        painter: PromptEntryDividerPainter(
          promptEntryDividerColor(context),
          verticalOffset: PromptEntryDivider.inlineStrokeOffset(bodyScale) *
              bodyScale /
              placeholderScale,
        ),
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
