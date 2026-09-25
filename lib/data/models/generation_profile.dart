import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';

/// One complete, independently persisted set of generation inputs.
///
/// Random and fixed modes deliberately own separate instances of every field
/// here. Switching mode never copies or clears values from the other profile.
class GenerationProfile {
  PromptConfig rootPromptConfig;
  PromptConfig negativePromptConfig;
  List<CharacterConfig> characterConfigList;
  List<PromptConfig> savedPromptConfigList;
  ParamConfig paramConfig;
  int generationCount;
  int generationIntervalSec;
  bool lockToAllCombinations;

  GenerationProfile({
    required this.rootPromptConfig,
    required this.negativePromptConfig,
    required this.characterConfigList,
    required this.savedPromptConfigList,
    required this.paramConfig,
    this.generationCount = 0,
    this.generationIntervalSec = 2,
    this.lockToAllCombinations = false,
  });

  GenerationProfile copy() => GenerationProfile.fromJson(toJson());

  Map<String, dynamic> toJson() {
    return {
      'prompt_config': rootPromptConfig.toJson(),
      'negative_prompt_config': negativePromptConfig.toJson(),
      'character_config':
          characterConfigList.map((config) => config.toJson()).toList(),
      'saved_config':
          savedPromptConfigList.map((config) => config.toJson()).toList(),
      'param_config': paramConfig.toJson(),
      'generation_count': generationCount,
      'generation_interval': generationIntervalSec,
      'lock_to_all_combinations': lockToAllCombinations,
    };
  }

  factory GenerationProfile.fromJson(
    Map<String, dynamic> json, {
    int defaultGenerationCount = 0,
    int defaultGenerationIntervalSec = 2,
    bool defaultLockToAllCombinations = false,
  }) {
    final characters = (json['character_config'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(CharacterConfig.fromJson)
        .toList();
    final saved = (json['saved_config'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(PromptConfig.fromJson)
        .toList();
    return GenerationProfile(
      rootPromptConfig: PromptConfig.fromJson(
        json['prompt_config'] as Map<String, dynamic>? ?? _emptyPromptJson(),
      ),
      negativePromptConfig: PromptConfig.fromJson(
        json['negative_prompt_config'] as Map<String, dynamic>? ??
            _emptyPromptJson(comment: '负面内容'),
      ),
      characterConfigList: characters,
      savedPromptConfigList: saved,
      paramConfig: ParamConfig.fromJson(
        json['param_config'] as Map<String, dynamic>? ?? {},
      ),
      generationCount:
          json['generation_count'] as int? ?? defaultGenerationCount,
      generationIntervalSec:
          json['generation_interval'] as int? ?? defaultGenerationIntervalSec,
      lockToAllCombinations:
          json['lock_to_all_combinations'] as bool? ?? defaultLockToAllCombinations,
    );
  }

  static Map<String, dynamic> _emptyPromptJson({
    String comment = '提示词',
  }) {
    return PromptConfig(
      selectionMethod: 'all',
      shuffled: false,
      comment: comment,
      strs: [],
      prompts: [],
    ).toJson();
  }
}
