import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/ui/character_config/view_models/character_config_viewmodel.dart';

/// A free drag canvas used to position one or more characters on the generated
/// image. The canvas keeps the same aspect ratio as the first configured
/// generation size, and each character is shown as a draggable labeled point.
class CharacterFreePositionCanvas extends StatelessWidget {
  final CharacterConfigViewmodel viewmodel;
  final int characterIndex;
  final String? characterLabel;

  /// Optional ordered list of every character's free position (null when a
  /// character has not been placed yet). Used to display secondary
  /// (non-draggable) markers for the other characters in the scene.
  final List<Point<double>?>? referencePositions;

  const CharacterFreePositionCanvas({
    super.key,
    required this.viewmodel,
    this.characterIndex = 0,
    this.characterLabel,
    this.referencePositions,
  });

  @override
  Widget build(BuildContext context) {
    final GenerationSize size = viewmodel.firstGenerationSize;
    final double aspect =
        (size.width / size.height).isFinite && size.width > 0 && size.height > 0
            ? size.width / size.height
            : 832 / 1216;
    final Point<double>? center = viewmodel.config.freeCenter;

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
                onPanStart: (details) => _updateFromLocal(details.localPosition,
                    canvasWidth, canvasHeight, viewmodel),
                onPanUpdate: (details) => _updateFromLocal(
                    details.localPosition,
                    canvasWidth,
                    canvasHeight,
                    viewmodel),
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
                      if (center != null)
                        Positioned(
                          left: center.x.clamp(0.0, 1.0) * canvasWidth - 14,
                          top: center.y.clamp(0.0, 1.0) * canvasHeight - 14,
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
  }

  void _updateFromLocal(
    Offset local,
    double canvasWidth,
    double canvasHeight,
    CharacterConfigViewmodel vm,
  ) {
    if (canvasWidth <= 0 || canvasHeight <= 0) return;
    final double x = (local.dx / canvasWidth).clamp(0.0, 1.0);
    final double y = (local.dy / canvasHeight).clamp(0.0, 1.0);
    vm.setFreeCenter(Point<double>(x, y));
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
