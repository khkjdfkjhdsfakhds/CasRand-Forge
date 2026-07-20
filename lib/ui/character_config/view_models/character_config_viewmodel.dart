import 'dart:math';

import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/character_config.dart';
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

  String getPositionsTexts() {
    const Map<int, String> xMapping = {
      1: 'A',
      2: 'B',
      3: 'C',
      4: 'D',
      5: 'E',
    };
    List<String> ret = [];
    for (final point in config.positions) {
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
    if (autoPosition || config.positions.contains(pt)) return;
    config.positions = [pt];
    notifyListeners();
  }

  void setAutoPosition(bool? value) {
    if (value == null) return;
    if (onAutoPositionChanged != null) {
      onAutoPositionChanged!(value);
    } else {
      paramConfig.autoPosition = value;
      if (!value && config.positions.isEmpty) {
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
