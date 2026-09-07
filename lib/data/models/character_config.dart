import 'dart:math';

import 'package:nai_casrand/data/models/prompt_config.dart';

class CharacterPromptResult {
  /// Normalized (0..1) center position, either from a V5 free-point drag or
  /// derived from the legacy discrete grid. This is the value written into
  /// `v4_prompt.caption.char_captions[].centers[]`.
  Point<double> center;
  NestedPrompt prompt;
  NestedPrompt uc;

  /// True when [center] came from a V5 free-position (custom canvas) point.
  bool isFreePosition;

  /// Legacy grid label such as `C3`, only set when [isFreePosition] is false.
  String? gridLabel;

  CharacterPromptResult({
    required this.center,
    required this.prompt,
    required this.uc,
    this.isFreePosition = false,
    this.gridLabel,
  });
}

class CharacterConfig {
  static const Point<int> defaultPosition = Point<int>(3, 3);
  static const String genderUnset = '';
  static const String genderFemale = 'female';
  static const String genderMale = 'male';
  static const String genderOther = 'other';

  /// Normalized grid positions (legacy V4.5). Kept for backward compatibility.
  List<Point<int>> positions;

  /// V5 free-position center in normalized (0..1) coordinates. When set it
  /// overrides [positions] completely for the generated payload.
  Point<double>? freeCenter;

  PromptConfig positivePromptConfig;
  PromptConfig negativePromptConfig;

  /// Optional display label; never included in generated prompt text.
  String name;
  String gender;
  bool enabled;

  CharacterConfig({
    this.name = '',
    required this.positions,
    this.freeCenter,
    required this.positivePromptConfig,
    required this.negativePromptConfig,
    required this.gender,
    required this.enabled,
  });

  static String _gridLabel(Point<int> p) {
    const labels = {1: 'A', 2: 'B', 3: 'C', 4: 'D', 5: 'E'};
    return '${labels[p.x] ?? ''}${p.y}';
  }

  static const Map<int, double> gridToNormalized = {
    0: 0.0,
    1: 0.1,
    2: 0.3,
    3: 0.5,
    4: 0.7,
    5: 0.9,
  };

  CharacterPromptResult getPrompt({List<PromptConfig>? savedConfigs}) {
    final random = Random();
    final promptResult =
        positivePromptConfig.getPrmpts(savedConfigs: savedConfigs);
    final Point<double> center;
    final bool isFreePosition;
    final Point<int> positionAsInt;
    if (freeCenter != null) {
      center = freeCenter!;
      isFreePosition = true;
      positionAsInt = defaultPosition;
    } else {
      if (positions.isNotEmpty) {
        positionAsInt = positions[random.nextInt(positions.length)];
      } else {
        positionAsInt = defaultPosition;
      }
      center = Point<double>(
        gridToNormalized[positionAsInt.x] ?? 0.5,
        gridToNormalized[positionAsInt.y] ?? 0.5,
      );
      isFreePosition = false;
    }
    return CharacterPromptResult(
      center: center,
      prompt: promptResult,
      uc: negativePromptConfig.getPrmpts(savedConfigs: savedConfigs),
      isFreePosition: isFreePosition,
      gridLabel: isFreePosition ? null : _gridLabel(positionAsInt),
    );
  }

  factory CharacterConfig.fromEmpty() {
    return CharacterConfig(
      positions: [defaultPosition],
      positivePromptConfig: PromptConfig(
        shuffled: false,
        comment: '提示词',
        strs: [],
        prompts: [],
      ),
      negativePromptConfig: PromptConfig(
        shuffled: false,
        comment: '负面内容',
        strs: [],
        prompts: [],
      ),
      gender: genderUnset,
      enabled: true,
    );
  }

  factory CharacterConfig.fromJson(Map<String, dynamic> json) {
    final positionsJson = json['positions'] as List<dynamic>? ?? [];
    final positions = positionsJson.map((position) {
      final point = position as Map<String, dynamic>;
      return Point<int>(point['x'], point['y']);
    }).toList();
    final positivePromptConfig =
        PromptConfig.fromJson(json['positivePromptConfig']);
    if (positivePromptConfig.comment == 'Unnamed config') {
      positivePromptConfig.comment = '提示词';
    }
    final negativePromptConfigJson = json['negativePromptConfig'];
    final negativePromptConfig =
        negativePromptConfigJson is Map<String, dynamic>
            ? PromptConfig.fromJson(negativePromptConfigJson)
            : _negativePromptConfigFromLegacy(json['negativePrompt'] ?? '');
    final gender = switch (json['gender']) {
      genderFemale => genderFemale,
      genderMale => genderMale,
      genderOther => genderOther,
      _ => genderUnset,
    };

    return CharacterConfig(
      positions: [positions.isEmpty ? defaultPosition : positions.first],
      positivePromptConfig: positivePromptConfig,
      negativePromptConfig: negativePromptConfig,
      gender: gender,
      name: json['name'] is String ? json['name'] as String : '',
      enabled: json['enabled'] ?? true,
      freeCenter: _freeCenterFromJson(json['freeCenter']),
    );
  }

  static Point<double>? _freeCenterFromJson(dynamic raw) {
    if (raw is! Map) return null;
    final x = raw['x'];
    final y = raw['y'];
    if (x is! num || y is! num) return null;
    return Point<double>(x.toDouble(), y.toDouble());
  }

  void setGender(String value) {
    if (value != genderFemale && value != genderMale && value != genderOther) {
      return;
    }
    final previousGender = gender;
    gender = value;
    if (value == genderOther) {
      if (previousGender == genderFemale || previousGender == genderMale) {
        final target = _findFirstUsableStringConfig(positivePromptConfig);
        final index = target?.firstUsableEntryIndex;
        if (target != null && index != null) {
          target.strs[index] = _mapFirstPromptLine(
            target.strs[index],
            _removeBinaryGenderPrefix,
          );
        }
      }
      return;
    }

    final target = _findFirstUsableStringConfig(positivePromptConfig) ??
        _findFirstStringConfig(positivePromptConfig) ??
        _insertFirstStringConfig(positivePromptConfig);
    final prefix = value == genderFemale ? 'girl' : 'boy';
    final index = target.firstUsableEntryIndex;
    if (index == null) {
      target.strs.add('$prefix,');
      return;
    }
    target.strs[index] = _mapFirstPromptLine(
      target.strs[index],
      (line) => _replaceGenderPrefix(line, prefix),
    );
  }

  static PromptConfig? _findFirstUsableStringConfig(PromptConfig config) {
    if (config.type == 'str' && config.firstUsableEntryIndex != null) {
      return config;
    }
    for (final child in config.prompts) {
      final result = _findFirstUsableStringConfig(child);
      if (result != null) return result;
    }
    return null;
  }

  static PromptConfig? _findFirstStringConfig(PromptConfig config) {
    if (config.type == 'str') return config;
    for (final child in config.prompts) {
      final result = _findFirstStringConfig(child);
      if (result != null) return result;
    }
    return null;
  }

  static PromptConfig _insertFirstStringConfig(PromptConfig config) {
    final inserted = PromptConfig(
      shuffled: false,
      comment: '提示词',
      strs: [],
      prompts: [],
    );
    config.prompts.insert(0, inserted);
    return inserted;
  }

  static String _replaceGenderPrefix(String content, String prefix) {
    final leadingGender = RegExp(
      r'^\s*(?:1?(?:girl|boy|other))(?=\s*(?:,|$))\s*,?\s*',
      caseSensitive: false,
    );
    final remainder = content.replaceFirst(leadingGender, '').trimLeft();
    return remainder.isEmpty ? '$prefix,' : '$prefix, $remainder';
  }

  static String _removeBinaryGenderPrefix(String content) {
    final leadingBinaryGender = RegExp(
      r'^\s*(?:1?(?:girl|boy))(?=\s*(?:,|$))\s*,?\s*',
      caseSensitive: false,
    );
    return content.replaceFirst(leadingBinaryGender, '').trimLeft();
  }

  static String _mapFirstPromptLine(
    String content,
    String Function(String) transform,
  ) {
    final lines = content.split('\n');
    final index = lines.indexWhere(
      (line) => !PromptConfig.isCommentLine(line) && line.trim().isNotEmpty,
    );
    if (index < 0) return content;
    lines[index] = transform(lines[index]);
    return lines.join('\n');
  }

  static PromptConfig _negativePromptConfigFromLegacy(String value) {
    return PromptConfig(
      shuffled: false,
      comment: '负面内容',
      strs: value.isEmpty ? [] : [value],
      prompts: [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'positions': positions.map((point) {
        return {
          'x': point.x,
          'y': point.y,
        };
      }).toList(),
      'freeCenter':
          freeCenter == null ? null : {'x': freeCenter!.x, 'y': freeCenter!.y},
      'positivePromptConfig': positivePromptConfig.toJson(),
      'negativePromptConfig': negativePromptConfig.toJson(),
      if (name.isNotEmpty) 'name': name,
      'gender': gender,
      'enabled': enabled,
    };
  }
}
