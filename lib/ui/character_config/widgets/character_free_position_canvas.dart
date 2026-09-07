import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';

/// A free drag canvas used to position one or more characters on the generated
/// image. The canvas keeps the same aspect ratio as the first configured
/// generation size, and each character is shown as a draggable labeled point.
///
/// The X / Y coordinate text fields live in the dialog actions (left of
/// Confirm); when provided, [xController] / [yController] are kept in sync with
/// the dragged point so both the canvas and the typed inputs agree.
class CharacterFreePositionCanvas extends StatelessWidget {
  final CharacterConfigViewmodel viewmodel;
  final int characterIndex;
  final String? characterLabel;

  /// Optional ordered list of every character's free position (null when a
  /// character has not been placed yet). Used to display secondary
  /// (non-draggable) markers for the other characters in the scene.
  final List<Point<double>?>? referencePositions;

  /// Optional external controllers for the X / Y inputs shown in the dialog.
  final TextEditingController? xController;
  final TextEditingController? yController;

  const CharacterFreePositionCanvas({
    super.key,
    required this.viewmodel,
    this.characterIndex = 0,
    this.characterLabel,
    this.referencePositions,
    this.xController,
    this.yController,
  });

  String _fmt(double v) => v.toStringAsFixed(3);

  void _updateFromLocal(
    Offset local,
    double canvasWidth,
    double canvasHeight,
  ) {
    if (canvasWidth <= 0 || canvasHeight <= 0) return;
    final double x = (local.dx / canvasWidth).clamp(0.0, 1.0);
    final double y = (local.dy / canvasHeight).clamp(0.0, 1.0);
    // Keep the coordinate inputs in sync with the dragged point.
    xController?.text = _fmt(x);
    yController?.text = _fmt(y);
    viewmodel.setFreeCenter(Point<double>(x, y));
  }

  @override
  Widget build(BuildContext context) {
    // Listen to the viewmodel so the marker follows the pointer / typed values
    // in real time rather than only after the dialog is reopened.
    return ListenableBuilder(
      listenable: viewmodel,
      builder: (context, _) {
        final GenerationSize size = viewmodel.firstGenerationSize;
        final double aspect = (size.width / size.height).isFinite &&
                size.width > 0 &&
                size.height > 0
            ? size.width / size.height
            : 832 / 1216;
        final Point<double>? center = viewmodel.config.freeCenter;
        final Point<double> display = center ?? const Point<double>(0.5, 0.5);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: aspect,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final double canvasWidth = constraints.maxWidth;
                  final double canvasHeight = constraints.maxHeight;
                  return GestureDetector(
                    key: const Key('character-free-canvas'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) => _updateFromLocal(
                        details.localPosition, canvasWidth, canvasHeight),
                    onPanUpdate: (details) => _updateFromLocal(
                        details.localPosition, canvasWidth, canvasHeight),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black12,
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Stack(
                        children: [
                          // Reference (non-editing) character markers.
                          if (referencePositions != null)
                            for (final (i, ref) in referencePositions!.indexed)
                              if (i != characterIndex && ref != null)
                                Positioned(
                                  left: ref.x * canvasWidth - 8,
                                  top: ref.y * canvasHeight - 8,
                                  child: IgnorePointer(
                                    child: _MarkerDot(
                                      radius: 9,
                                      label: '${i + 1}',
                                      color: Colors.white38,
                                    ),
                                  ),
                                ),
                          // The editable character point.
                          Positioned(
                            left: display.x.clamp(0.0, 1.0) * canvasWidth - 14,
                            top: display.y.clamp(0.0, 1.0) * canvasHeight - 14,
                            child: _MarkerDot(
                              radius: 14,
                              label: characterLabel ?? '${characterIndex + 1}',
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${size.width} × ${size.height}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

class _MarkerDot extends StatelessWidget {
  final double radius;
  final String? label;
  final Color color;

  const _MarkerDot({
    required this.radius,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: label == null
          ? null
          : Center(
              child: Text(
                label!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
    );
  }
}
