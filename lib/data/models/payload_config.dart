import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';

class PayloadResult {
  final String comment;
  final Map<String, dynamic> payload;

  const PayloadResult({
    required this.comment,
    required this.payload,
  });
}

const Map<int, String> xMapping = {
  0: 'X',
  1: 'A',
  2: 'B',
  3: 'C',
  4: 'D',
  5: 'E',
};

const Map<int, double> doubleMapping = {
  0: 0.0,
  1: 0.1,
  2: 0.3,
  3: 0.5,
  4: 0.7,
  5: 0.9
};

class PayloadConfig {
  PromptConfig rootPromptConfig;
  PromptConfig negativePromptConfig;
  List<CharacterConfig> characterConfigList;
  List<PromptConfig> savedPromptConfigList;

  ParamConfig paramConfig;

  Settings settings;

  I2IConfig i2iConfig = I2IConfig();
  List<VibeConfig> vibeConfigList = [];
  List<VibeConfigV4> vibeConfigListV4 = [];
  List<PreciseReferenceConfig> preciseReferenceConfigList = [];

  String overridePrompt;
  bool useOverridePrompt;
  bool useCharacterPromptWithOverride;

  PayloadConfig({
    required this.rootPromptConfig,
    required this.negativePromptConfig,
    required this.characterConfigList,
    required this.savedPromptConfigList,
    required this.paramConfig,
    required this.settings,
    required this.overridePrompt,
    required this.useOverridePrompt,
    required this.useCharacterPromptWithOverride,
  });

  Map<String, String> getHeaders() {
    return {
      "authorization": "Bearer ${settings.apiKey}",
      "referer": "https://novelai.net",
      "user-agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0"
    };
  }

  void resetSequentialState() {
    rootPromptConfig.resetSequentialState();
    negativePromptConfig.resetSequentialState();
    for (final config in savedPromptConfigList) {
      config.resetSequentialState();
    }
    for (final characterConfig in characterConfigList) {
      characterConfig.positivePromptConfig.resetSequentialState();
      characterConfig.negativePromptConfig.resetSequentialState();
    }
  }

  void resetTransientConfigs() {
    i2iConfig = I2IConfig();
    vibeConfigList.clear();
    vibeConfigListV4.clear();
    preciseReferenceConfigList.clear();
  }

  Map<String, dynamic> toJson() {
    return {
      "prompt_config": rootPromptConfig.toJson(),
      "negative_prompt_config": negativePromptConfig.toJson(),
      "character_config":
          characterConfigList.map((elem) => elem.toJson()).toList(),
      "saved_config":
          savedPromptConfigList.map((elem) => elem.toJson()).toList(),
      "param_config": paramConfig.toJson(),
      "settings": settings.toJson(),
      'override_prompt': overridePrompt,
      'use_override_prompt': useOverridePrompt,
      'use_character_prompt_with_override': useCharacterPromptWithOverride,
    };
  }

  factory PayloadConfig.fromJson(Map<String, dynamic> jsonData) {
    final jsonCharacterList = jsonData.containsKey('character_config')
        ? jsonData['character_config'] as List<dynamic>
        : [];
    final jsonSavedPromptList = jsonData.containsKey('saved_config')
        ? jsonData['saved_config'] as List<dynamic>
        : [];
    final characterList = jsonCharacterList
        .map((configJson) => CharacterConfig.fromJson(configJson))
        .toList();
    final savedList = jsonSavedPromptList
        .map((configJson) => PromptConfig.fromJson(configJson))
        .toList();
    final paramConfig = ParamConfig.fromJson(jsonData['param_config'] ?? {});
    final negativePromptConfigJson = jsonData['negative_prompt_config'];
    return PayloadConfig(
      rootPromptConfig: PromptConfig.fromJson(jsonData['prompt_config']),
      negativePromptConfig: negativePromptConfigJson is Map<String, dynamic>
          ? _negativePromptConfigFromJson(negativePromptConfigJson)
          : _negativePromptConfigFromLegacy(paramConfig.negativePrompt),
      characterConfigList: characterList,
      savedPromptConfigList: savedList,
      paramConfig: paramConfig,
      settings: Settings.fromJson(jsonData['settings'] ?? {}),
      overridePrompt: jsonData['override_prompt'] ?? '',
      useOverridePrompt: jsonData['use_override_prompt'] ?? false,
      useCharacterPromptWithOverride:
          jsonData['use_character_prompt_with_override'] ?? false,
    );
  }

  void loadJson(Map<String, dynamic> jsonData) {
    final jsonCharacterList = jsonData.containsKey('character_config')
        ? jsonData['character_config'] as List<dynamic>
        : [];
    final jsonSavedPromptList = jsonData.containsKey('saved_config')
        ? jsonData['saved_config'] as List<dynamic>
        : [];
    final characterList = jsonCharacterList.map((configJson) {
      return CharacterConfig.fromJson(configJson);
    }).toList();
    final savedList = jsonSavedPromptList
        .map((configJson) => PromptConfig.fromJson(configJson))
        .toList();
    rootPromptConfig = PromptConfig.fromJson(jsonData['prompt_config']);
    characterConfigList = characterList;
    savedPromptConfigList = savedList;
    paramConfig = ParamConfig.fromJson(jsonData['param_config'] ?? {});
    final negativePromptConfigJson = jsonData['negative_prompt_config'];
    negativePromptConfig = negativePromptConfigJson is Map<String, dynamic>
        ? _negativePromptConfigFromJson(negativePromptConfigJson)
        : _negativePromptConfigFromLegacy(paramConfig.negativePrompt);
    settings = Settings.fromJson(jsonData['settings'] ?? {});
    overridePrompt = jsonData['override_prompt'] ?? '';
    useOverridePrompt = jsonData['use_override_prompt'] ?? false;
    useCharacterPromptWithOverride =
        jsonData['use_character_prompt_with_override'] ?? false;
  }

  int loadParamJson(Map<String, dynamic> json) {
    final paramJson = Map<String, dynamic>.from(json);
    final v4Prompt = json['v4_prompt'];
    if (!paramJson.containsKey('use_coords') &&
        v4Prompt is Map &&
        v4Prompt['use_coords'] is bool) {
      paramJson['use_coords'] = v4Prompt['use_coords'];
    }
    final loadedCount = paramConfig.loadJson(paramJson);
    if (paramJson.containsKey('negative_prompt') ||
        paramJson.containsKey('uc')) {
      setNegativePromptFromString(paramConfig.negativePrompt);
    }
    return loadedCount;
  }

  void setNegativePromptFromString(String value) {
    final migrated = _negativePromptConfigFromLegacy(value);
    negativePromptConfig
      ..selectionMethod = migrated.selectionMethod
      ..shuffled = migrated.shuffled
      ..prob = migrated.prob
      ..num = migrated.num
      ..randomBracketsUpper = migrated.randomBracketsUpper
      ..randomBracketsLower = migrated.randomBracketsLower
      ..type = migrated.type
      ..comment = migrated.comment
      ..filter = migrated.filter
      ..strs = migrated.strs
      ..prompts = migrated.prompts
      ..enabled = migrated.enabled;
    negativePromptConfig.resetSequentialState();
    paramConfig.negativePrompt = value;
  }

  static PromptConfig _negativePromptConfigFromLegacy(String value) {
    return PromptConfig(
      selectionMethod: 'all',
      shuffled: false,
      comment: '负面内容',
      strs: value.isEmpty ? [] : [value],
      prompts: [],
    );
  }

  static PromptConfig _negativePromptConfigFromJson(
    Map<String, dynamic> json,
  ) {
    final config = PromptConfig.fromJson(json);
    if (config.comment == '反向提示词') {
      config.comment = '负面内容';
    }
    return config;
  }
}
