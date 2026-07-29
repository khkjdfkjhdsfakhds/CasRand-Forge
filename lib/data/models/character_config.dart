import 'dart:math';

import 'package:nai_casrand/data/models/prompt_config.dart';

class CharacterPromptResult {
  Point<int> center;
  NestedPrompt prompt;
  NestedPrompt uc;

  CharacterPromptResult({
    required this.center,
    required this.prompt,
    required this.uc,
  });
}

class CharacterConfig {
  static const Point<int> defaultPosition = Point<int>(3, 3);
  static const String genderUnset = '';
  static const String genderFemale = 'female';
  static const String genderMale = 'male';
  static const String genderOther = 'other';

  List<Point<int>> positions;
  PromptConfig positivePromptConfig;
  PromptConfig negativePromptConfig;
  String gender;
  bool enabled;

  CharacterConfig({
    required this.positions,
    required this.positivePromptConfig,
    required this.negativePromptConfig,
    required this.gender,
    required this.enabled,
  });

  CharacterPromptResult getPrompt() {
    final random = Random();
    final promptResult = positivePromptConfig.getPrmpts();
    final Point<int> positionAsInt;
    if (positions.isNotEmpty) {
      positionAsInt = positions[random.nextInt(positions.length)];
    } else {
      positionAsInt = defaultPosition;
    }
    return CharacterPromptResult(
      center: positionAsInt,
      prompt: promptResult,
      uc: negativePromptConfig.getPrmpts(),
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
      enabled: json['enabled'] ?? true,
    );
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
      'positivePromptConfig': positivePromptConfig.toJson(),
      'negativePromptConfig': negativePromptConfig.toJson(),
      'gender': gender,
      'enabled': enabled,
    };
  }
}
