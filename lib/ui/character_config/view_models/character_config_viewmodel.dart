import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';

class CharacterConfigViewmodel extends ChangeNotifier {
  CharacterConfig config;
  ParamConfig paramConfig;
  ValueChanged<bool>? onAutoPositionChanged;

  CharacterConfigViewmodel({
    required this.config,
    required this.paramConfig,
    this.onAutoPositionChanged,
  });

  bool get autoPosition => paramConfig.autoPosition;

  /// True when the selected model is NovelAI Diffusion V5, which uses a free
  /// (continuous) character-position canvas rather than the legacy grid.
  bool get isV5 => paramConfig.model.contains('diffusion-5');

  /// The first configured generation size, used to shape the free-position
  /// canvas. Falls back to the V5 default portrait size when empty.
  GenerationSize get firstGenerationSize {
    if (paramConfig.sizes.isNotEmpty) {
      return paramConfig.sizes.first;
    }
    return const GenerationSize(height: 1216, width: 832);
  }

  String getPositionsTexts() {
    final Point<double>? free = config.freeCenter;
    if (isV5 && free != null) {
      return 'x:${free.x.toStringAsFixed(3)}, y:${free.y.toStringAsFixed(3)}';
    }
    const Map<int, String> xMapping = {
      1: 'A',
      2: 'B',
      3: 'C',
      4: 'D',
      5: 'E',
    };
    List<String> ret = [];
    for (final point in config.effectiveGridPositions) {
      String pt = '';
      pt += xMapping[point.x] ?? '';
      pt += point.y.toString();
      ret.add(pt);
    }

    return ret.join(', ');
  }

  void setGender(String value) {
    config.setGender(value);
    notifyListeners();
  }

  void switchPosition(Point<int> pt) {
    if (autoPosition ||
        (config.freeCenter == null && config.positions.contains(pt))) {
      return;
    }
    // Switching to a manual grid position clears the V5 free center so the
    // two position systems never conflict.
    config.freeCenter = null;
    config.positions = [pt];
    notifyListeners();
  }

  /// Sets the V5 free position in normalized (0..1) coordinates. Selecting a
  /// free point clears the legacy grid positions.
  void setFreeCenter(Point<double> center) {
    if (autoPosition) return;
    config.freeCenter = center;
    config.positions = [];
    notifyListeners();
  }

  void setAutoPosition(bool? value) {
    if (value == null) return;
    if (value) {
      // AI choice means that no explicit V5 point should remain active.
      config.freeCenter = null;
    }
    if (onAutoPositionChanged != null) {
      onAutoPositionChanged!(value);
    } else {
      paramConfig.autoPosition = value;
      if (!value && config.positions.isEmpty && config.freeCenter == null) {
        config.positions = [CharacterConfig.defaultPosition];
      }
    }
    notifyListeners();
  }

  void setEnabled(bool? value) {
    if (value == null) return;
    config.enabled = value;
    notifyListeners();
  }
}
