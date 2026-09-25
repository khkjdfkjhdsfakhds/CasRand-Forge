import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/character_config.dart';
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

  /// Fit the entire canvas into both available dimensions.
  final bool fitToBounds;

  /// Index of the character whose point is currently editable.
  final int? selectedCharacterIndex;

  /// Called when a reference marker is clicked.
  final ValueChanged<int>? onCharacterSelected;
  final String? characterLabel;

  /// Every character of the scene, in list order, so the other characters can
  /// be drawn as read-only reference markers while this one is edited.
  ///
  /// The live [CharacterConfig] instances are read on every build. Passing
  /// precomputed coordinates instead would freeze the markers at the moment
  /// the surrounding card was last built, which loses any position set later
  /// in the same session.
  final List<CharacterConfig>? referenceCharacters;

  /// Optional external controllers for the X / Y inputs shown in the dialog.
  final TextEditingController? xController;
  final TextEditingController? yController;

  /// Radius of the read-only markers for the other characters.
  static const double _referenceRadius = 11;

  /// Radius of the edited character's marker.
  static const double _editedRadius = 14;

  /// Click target around a reference marker. The visible dot stays compact,
  /// while the larger target makes switching characters easier.
  static const double _referenceTapSize = 36;

  const CharacterFreePositionCanvas({
    super.key,
    required this.viewmodel,
    this.characterIndex = 0,
    this.fitToBounds = false,
    this.selectedCharacterIndex,
    this.onCharacterSelected,
    this.characterLabel,
    this.referenceCharacters,
    this.xController,
    this.yController,
  });

  String _fmt(double v) => v.toStringAsFixed(3);

  void _updateFromLocal(
    Offset local,
    double canvasWidth,
    double canvasHeight,
    CharacterConfig character,
  ) {
    if (canvasWidth <= 0 || canvasHeight <= 0) return;
    final double x = (local.dx / canvasWidth).clamp(0.0, 1.0);
    final double y = (local.dy / canvasHeight).clamp(0.0, 1.0);
    // Keep the coordinate inputs in sync with the dragged point.
    xController?.text = _fmt(x);
    yController?.text = _fmt(y);
    viewmodel.setFreeCenterFor(character, Point<double>(x, y));
  }

  /// Where a character will actually be rendered right now: its V5 free point
  /// when one is set, otherwise the center of every explicit legacy grid cell
  /// it still uses. Characters without an explicit position stay unmarked so
  /// the AI-choice default is not mistaken for a deliberate placement.
  static List<Point<double>> placedCenters(CharacterConfig character) {
    final Point<double>? free = character.freeCenter;
    if (free != null) return [free];
    return [
      for (final Point<int> cell in character.positions)
        Point<double>(
          CharacterConfig.gridToNormalized[cell.x] ?? 0.5,
          CharacterConfig.gridToNormalized[cell.y] ?? 0.5,
        ),
    ];
  }

  static Point<double> displayCenter(CharacterConfig character) {
    final centers = placedCenters(character);
    return centers.isEmpty ? const Point<double>(0.5, 0.5) : centers.first;
  }

  /// Read-only markers for the other characters, paired with their index.
  List<(int, Point<double>)> _referenceDots() {
    final List<CharacterConfig>? characters = referenceCharacters;
    if (characters == null) return const [];
    final selected = selectedCharacterIndex ?? characterIndex;
    return [
      for (final (int i, CharacterConfig character) in characters.indexed)
        if (i != selected)
          for (final Point<double> center in placedCenters(character))
            (i, center),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
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
        final int selected = selectedCharacterIndex ?? characterIndex;
        final CharacterConfig selectedCharacter = referenceCharacters != null &&
                selected >= 0 &&
                selected < referenceCharacters!.length
            ? referenceCharacters![selected]
            : viewmodel.config;
        final Point<double> display = displayCenter(selectedCharacter);
        final List<(int, Point<double>)> references = _referenceDots();

        final canvas = AspectRatio(
          aspectRatio: aspect,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double canvasWidth = constraints.maxWidth;
              final double canvasHeight = constraints.maxHeight;
              return GestureDetector(
                key: const Key('character-free-canvas'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) => _updateFromLocal(details.localPosition,
                    canvasWidth, canvasHeight, selectedCharacter),
                onPanUpdate: (details) => _updateFromLocal(
                    details.localPosition,
                    canvasWidth,
                    canvasHeight,
                    selectedCharacter),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    border: Border.all(color: Colors.white24),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(
                    children: [
                      // Reference (non-editing) character markers.
                      for (final (int index, Point<double> point) in references)
                        Positioned(
                          left: point.x.clamp(0.0, 1.0) * canvasWidth -
                              _referenceTapSize / 2,
                          top: point.y.clamp(0.0, 1.0) * canvasHeight -
                              _referenceTapSize / 2,
                          child: GestureDetector(
                            key: Key('character-free-marker-${index + 1}'),
                            behavior: HitTestBehavior.opaque,
                            onTap: onCharacterSelected == null
                                ? null
                                : () => onCharacterSelected!(index),
                            child: SizedBox.square(
                              dimension: _referenceTapSize,
                              child: Center(
                                child: _MarkerDot(
                                  radius: _referenceRadius,
                                  label: '${index + 1}',
                                  color: colorScheme.surface,
                                  borderColor: colorScheme.outline,
                                  textColor: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // The editable character point.
                      Positioned(
                        left: display.x.clamp(0.0, 1.0) * canvasWidth -
                            _editedRadius,
                        top: display.y.clamp(0.0, 1.0) * canvasHeight -
                            _editedRadius,
                        child: _MarkerDot(
                          radius: _editedRadius,
                          label: characterLabel ?? '${selected + 1}',
                          color: colorScheme.primary,
                          borderColor: colorScheme.onPrimary,
                          textColor: colorScheme.onPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (fitToBounds) Expanded(child: Center(child: canvas)) else canvas,
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
  final Color borderColor;
  final Color textColor;

  const _MarkerDot({
    required this.radius,
    required this.label,
    required this.color,
    required this.borderColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: borderColor, width: 2),
      ),
      child: label == null
          ? null
          : Center(
              child: Text(
                label!,
                style: TextStyle(
                  color: textColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
    );
  }
}
