import 'dart:math';
import 'dart:typed_data';

import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/data/models/enhance_config.dart';
import 'package:nai_casrand/data/models/generation_profile.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/image_import_capabilities.dart';
import 'package:nai_casrand/data/models/metadata_import_options.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart'
    show defaultContextPx;
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';

class PayloadResult {
  final String comment;
  final Map<String, dynamic> payload;

  const PayloadResult({required this.comment, required this.payload});
}

I2iSizeMode _i2iSizeModeFromJson(dynamic value) {
  return I2iSizeMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => I2iSizeMode.automatic,
  );
}

enum PromptMode { random, fixed }

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
  5: 0.9,
};

class PayloadConfig {
  GenerationProfile randomProfile;
  GenerationProfile fixedProfile;
  PromptMode promptMode;

  GenerationProfile get activeProfile =>
      promptMode == PromptMode.fixed ? fixedProfile : randomProfile;

  PromptConfig get rootPromptConfig => activeProfile.rootPromptConfig;
  set rootPromptConfig(PromptConfig value) =>
      activeProfile.rootPromptConfig = value;
  PromptConfig get negativePromptConfig => activeProfile.negativePromptConfig;
  set negativePromptConfig(PromptConfig value) =>
      activeProfile.negativePromptConfig = value;
  List<CharacterConfig> get characterConfigList =>
      activeProfile.characterConfigList;
  set characterConfigList(List<CharacterConfig> value) =>
      activeProfile.characterConfigList = value;
  List<PromptConfig> get savedPromptConfigList =>
      activeProfile.savedPromptConfigList;
  set savedPromptConfigList(List<PromptConfig> value) =>
      activeProfile.savedPromptConfigList = value;
  ParamConfig get paramConfig => activeProfile.paramConfig;
  set paramConfig(ParamConfig value) => activeProfile.paramConfig = value;

  Settings settings;

  int addVibeImage(
    Uint8List bytes,
    String fileName, {
    double referenceStrength = 0.6,
    double informationExtracted = 0.7,
  }) {
    final capabilities = ImageImportCapabilities.forModel(paramConfig.model);
    if (!capabilities.supports(ImageImportAction.vibeTransfer)) return 0;
    final wasEmpty = !hasVibeResources;
    if (capabilities.isV4Family) {
      vibeConfigListV4.add(
        VibeConfigV4.fromImageBytes(
          fileName,
          bytes,
          referenceStrength,
          informationExtracted: informationExtracted,
          model: paramConfig.model,
        ),
      );
    } else {
      vibeConfigList.add(
        VibeConfig.fromBytes(bytes, fileName, 1.0, 0.3),
      );
    }
    noteVibeImported(wasEmpty: wasEmpty);
    return 1;
  }

  Future<bool> addPreciseReferenceImage(
    Uint8List bytes,
    String fileName,
  ) async {
    final capabilities = ImageImportCapabilities.forModel(paramConfig.model);
    if (!capabilities.supports(ImageImportAction.preciseReference)) {
      return false;
    }
    final wasEmpty = preciseReferenceConfigList.isEmpty;
    final reference = await PreciseReferenceConfig.fromBytes(bytes, fileName);
    preciseReferenceConfigList.add(reference);
    notePreciseReferenceImported(wasEmpty: wasEmpty);
    return true;
  }

  I2IConfig i2iConfig = I2IConfig();
  EnhanceConfig enhanceConfig = EnhanceConfig();
  DirectorToolConfig directorToolConfig = DirectorToolConfig();
  List<VibeConfig> vibeConfigList = [];
  List<VibeConfigV4> vibeConfigListV4 = [];
  List<PreciseReferenceConfig> preciseReferenceConfigList = [];
  bool i2iEnabled = false;
  bool vibeEnabled = false;
  bool preciseReferenceEnabled = false;
  bool _i2iManuallyDisabled = false;
  bool _vibeManuallyDisabled = false;
  bool _preciseReferenceManuallyDisabled = false;

  bool get hasVibeResources =>
      vibeConfigList.isNotEmpty || vibeConfigListV4.isNotEmpty;

  int get totalCombinations {
    if (promptMode == PromptMode.fixed) return 1;
    var total = rootPromptConfig.calculateCombinations();
    for (final char in characterConfigList) {
      if (char.enabled) {
        final charComb = char.positivePromptConfig.calculateCombinations();
        if (charComb > 0) {
          total *= charComb;
        }
      }
    }
    return max(1, total);
  }

  List<String> collectPrefixComments() {
    if (promptMode == PromptMode.fixed) return const [];
    final result = <String>[];
    result.addAll(rootPromptConfig.collectPrefixComments());
    for (final char in characterConfigList) {
      if (char.enabled) {
        result.addAll(char.positivePromptConfig.collectPrefixComments());
      }
    }
    return result;
  }

  void setI2iEnabled(bool value, {bool userAction = true}) {
    i2iEnabled = value && i2iConfig.hasImage;
    if (userAction) _i2iManuallyDisabled = !value;
  }

  void noteI2iImported({required bool replacing, bool explicitUse = false}) {
    if (explicitUse || !replacing || !_i2iManuallyDisabled) i2iEnabled = true;
  }

  void clearI2iResourceState() {
    i2iEnabled = false;
    _i2iManuallyDisabled = false;
  }

  void setVibeEnabled(bool value, {bool userAction = true}) {
    vibeEnabled = value && hasVibeResources;
    if (userAction) _vibeManuallyDisabled = !value;
    if (vibeEnabled) preciseReferenceEnabled = false;
  }

  void noteVibeImported({required bool wasEmpty, bool explicitUse = false}) {
    if (explicitUse || (wasEmpty && !_vibeManuallyDisabled)) {
      vibeEnabled = true;
      preciseReferenceEnabled = false;
    }
  }

  void clearVibeResourceState() {
    vibeEnabled = false;
    _vibeManuallyDisabled = false;
  }

  void setPreciseReferenceEnabled(bool value, {bool userAction = true}) {
    preciseReferenceEnabled = value && preciseReferenceConfigList.isNotEmpty;
    if (userAction) _preciseReferenceManuallyDisabled = !value;
    if (preciseReferenceEnabled) vibeEnabled = false;
  }

  void notePreciseReferenceImported(
      {required bool wasEmpty, bool explicitUse = false}) {
    if (explicitUse || (wasEmpty && !_preciseReferenceManuallyDisabled)) {
      preciseReferenceEnabled = true;
      vibeEnabled = false;
    }
  }

  void clearPreciseReferenceResourceState() {
    preciseReferenceEnabled = false;
    _preciseReferenceManuallyDisabled = false;
  }

  /// Compatibility accessors for pre-profile code and old saved files.
  String get overridePrompt => _plainPrompt(fixedProfile.rootPromptConfig);
  set overridePrompt(String value) =>
      fixedProfile.rootPromptConfig = fixedPromptConfig(value);
  bool get useOverridePrompt => promptMode == PromptMode.fixed;
  set useOverridePrompt(bool value) =>
      promptMode = value ? PromptMode.fixed : PromptMode.random;
  bool get useCharacterPromptWithOverride =>
      fixedProfile.characterConfigList.any((character) => character.enabled);
  set useCharacterPromptWithOverride(bool value) {
    for (final character in fixedProfile.characterConfigList) {
      character.enabled = value;
    }
  }

  PayloadConfig({
    required PromptConfig rootPromptConfig,
    required PromptConfig negativePromptConfig,
    required List<CharacterConfig> characterConfigList,
    required List<PromptConfig> savedPromptConfigList,
    required ParamConfig paramConfig,
    required this.settings,
    required String overridePrompt,
    required bool useOverridePrompt,
    required bool useCharacterPromptWithOverride,
    GenerationProfile? fixedProfile,
    PromptMode? promptMode,
    GenerationSize? i2iRequestSize,
    I2iSizeMode i2iSizeMode = I2iSizeMode.automatic,
    int i2iContextPx = defaultContextPx,
    bool i2iUseRandomSeed = false,
  })  : randomProfile = GenerationProfile(
          rootPromptConfig: rootPromptConfig,
          negativePromptConfig: negativePromptConfig,
          characterConfigList: characterConfigList,
          savedPromptConfigList: savedPromptConfigList,
          paramConfig: paramConfig,
        ),
        fixedProfile = fixedProfile ??
            GenerationProfile(
              rootPromptConfig: fixedPromptConfig(overridePrompt),
              negativePromptConfig: fixedPromptConfig(
                paramConfig.negativePrompt,
                negative: true,
              ),
              characterConfigList: useCharacterPromptWithOverride
                  ? characterConfigList
                      .map(
                        (config) => CharacterConfig.fromJson(config.toJson()),
                      )
                      .toList()
                  : [],
              savedPromptConfigList: [],
              paramConfig: ParamConfig.fromJson(paramConfig.toJson()),
            ),
        promptMode = promptMode ??
            (useOverridePrompt ? PromptMode.fixed : PromptMode.random) {
    i2iConfig = I2IConfig(
      requestSize: i2iRequestSize ??
          (paramConfig.sizes.isNotEmpty
              ? paramConfig.sizes.first
              : const GenerationSize(width: 832, height: 1216)),
      sizeMode: i2iSizeMode,
      contextPx: i2iContextPx,
      useRandomSeed: i2iUseRandomSeed,
    );
  }

  Map<String, String> getHeaders() {
    return getHeadersForToken(settings.apiKey);
  }

  Map<String, String> getHeadersForToken(String token) {
    return {
      "authorization": "Bearer $token",
      "referer": "https://novelai.net",
      "user-agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:126.0) Gecko/20100101 Firefox/126.0",
    };
  }

  void resetSequentialState() {
    for (final profile in [randomProfile, fixedProfile]) {
      profile.rootPromptConfig.resetSequentialState();
      profile.negativePromptConfig.resetSequentialState();
      for (final config in profile.savedPromptConfigList) {
        config.resetSequentialState();
      }
      for (final characterConfig in profile.characterConfigList) {
        characterConfig.positivePromptConfig.resetSequentialState();
        characterConfig.negativePromptConfig.resetSequentialState();
      }
    }
  }

  void resetTransientConfigs() {
    i2iConfig = I2IConfig(
      requestSize: i2iConfig.requestSize,
      sizeMode: i2iConfig.sizeMode,
      contextPx: i2iConfig.contextPx,
      useRandomSeed: i2iConfig.useRandomSeed,
    );
    enhanceConfig = EnhanceConfig();
    directorToolConfig = DirectorToolConfig();
    vibeConfigList.clear();
    vibeConfigListV4.clear();
    preciseReferenceConfigList.clear();
    i2iEnabled = false;
    vibeEnabled = false;
    preciseReferenceEnabled = false;
    _i2iManuallyDisabled = false;
    _vibeManuallyDisabled = false;
    _preciseReferenceManuallyDisabled = false;
  }

  Map<String, dynamic> toJson() {
    return {
      "prompt_config": randomProfile.rootPromptConfig.toJson(),
      "negative_prompt_config": randomProfile.negativePromptConfig.toJson(),
      "character_config": randomProfile.characterConfigList
          .map((elem) => elem.toJson())
          .toList(),
      "saved_config": randomProfile.savedPromptConfigList
          .map((elem) => elem.toJson())
          .toList(),
      "param_config": randomProfile.paramConfig.toJson(),
      "settings": settings.toJson(),
      'override_prompt': overridePrompt,
      'use_override_prompt': useOverridePrompt,
      'use_character_prompt_with_override': useCharacterPromptWithOverride,
      'prompt_mode': promptMode.name,
      'fixed_profile': fixedProfile.toJson(),
      'i2i_request_size': i2iConfig.requestSize.toJson(),
      'i2i_size_mode': i2iConfig.sizeMode.name,
      'i2i_context_px': i2iConfig.contextPx,
      'i2i_use_random_seed': i2iConfig.useRandomSeed,
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
    final fixedJson = jsonData['fixed_profile'];
    final i2iSizeJson = jsonData['i2i_request_size'];
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
      fixedProfile: fixedJson is Map<String, dynamic>
          ? GenerationProfile.fromJson(fixedJson)
          : null,
      promptMode: _promptModeFromJson(jsonData),
      i2iRequestSize: i2iSizeJson is Map<String, dynamic>
          ? GenerationSize.fromJson(i2iSizeJson)
          : (paramConfig.sizes.isNotEmpty ? paramConfig.sizes.first : null),
      i2iSizeMode: _i2iSizeModeFromJson(jsonData['i2i_size_mode']),
      i2iContextPx: jsonData['i2i_context_px'] is num
          ? (jsonData['i2i_context_px'] as num).round()
          : defaultContextPx,
      i2iUseRandomSeed: jsonData['i2i_use_random_seed'] == true,
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
    final randomParamConfig = ParamConfig.fromJson(
      jsonData['param_config'] ?? {},
    );
    final negativePromptConfigJson = jsonData['negative_prompt_config'];
    randomProfile = GenerationProfile(
      rootPromptConfig: PromptConfig.fromJson(jsonData['prompt_config']),
      characterConfigList: characterList,
      savedPromptConfigList: savedList,
      paramConfig: randomParamConfig,
      negativePromptConfig: negativePromptConfigJson is Map<String, dynamic>
          ? _negativePromptConfigFromJson(negativePromptConfigJson)
          : _negativePromptConfigFromLegacy(randomParamConfig.negativePrompt),
    );
    final loadedSettings = Settings.fromJson(jsonData['settings'] ?? {});
    final liveNavigation = settings.navigation;
    final loadedNavigation = loadedSettings.navigation;
    loadedSettings.navigation = liveNavigation;
    settings = loadedSettings;
    liveNavigation.replaceWith(loadedNavigation);
    final fixedJson = jsonData['fixed_profile'];
    fixedProfile = fixedJson is Map<String, dynamic>
        ? GenerationProfile.fromJson(fixedJson)
        : GenerationProfile(
            rootPromptConfig: fixedPromptConfig(
              jsonData['override_prompt'] ?? '',
            ),
            negativePromptConfig: fixedPromptConfig(
              randomParamConfig.negativePrompt,
              negative: true,
            ),
            characterConfigList:
                jsonData['use_character_prompt_with_override'] == true
                    ? characterList
                        .map(
                          (config) => CharacterConfig.fromJson(config.toJson()),
                        )
                        .toList()
                    : [],
            savedPromptConfigList: [],
            paramConfig: ParamConfig.fromJson(randomParamConfig.toJson()),
          );
    promptMode = _promptModeFromJson(jsonData);
    final i2iSizeJson = jsonData['i2i_request_size'];
    i2iConfig.setRequestSize(
      i2iSizeJson is Map<String, dynamic>
          ? GenerationSize.fromJson(i2iSizeJson)
          : (randomParamConfig.sizes.isNotEmpty
              ? randomParamConfig.sizes.first
              : const GenerationSize(width: 832, height: 1216)),
      mode: _i2iSizeModeFromJson(jsonData['i2i_size_mode']),
    );
    i2iConfig.setContextPx(
      jsonData['i2i_context_px'] is num
          ? (jsonData['i2i_context_px'] as num).round()
          : defaultContextPx,
    );
    i2iConfig.setUseRandomSeed(jsonData['i2i_use_random_seed'] == true);
  }

  /// Metadata always targets the fixed profile. It must never alter the
  /// random profile's prompts, negative cascade, seed mode, or other params.
  int loadParamJson(Map<String, dynamic> json) {
    final paramJson = Map<String, dynamic>.from(json);
    final v4Prompt = json['v4_prompt'];
    if (!paramJson.containsKey('use_coords') &&
        v4Prompt is Map &&
        v4Prompt['use_coords'] is bool) {
      paramJson['use_coords'] = v4Prompt['use_coords'];
    }
    final loadedCount = fixedProfile.paramConfig.loadJson(paramJson);
    final negative = _metadataNegativePrompt(json);
    if (negative != null) {
      fixedProfile.negativePromptConfig = fixedPromptConfig(
        negative,
        negative: true,
      );
      fixedProfile.paramConfig.negativePrompt = negative;
    }
    promptMode = PromptMode.fixed;
    return loadedCount;
  }

  void setNegativePromptFromString(String value) {
    if (promptMode == PromptMode.fixed) {
      fixedProfile.negativePromptConfig = fixedPromptConfig(
        value,
        negative: true,
      );
      fixedProfile.paramConfig.negativePrompt = value;
      return;
    }
    final migrated = _negativePromptConfigFromLegacy(value);
    randomProfile.negativePromptConfig
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
    randomProfile.negativePromptConfig.resetSequentialState();
    randomProfile.paramConfig.negativePrompt = value;
  }

  int importMetadataToFixedProfile(
    Map<String, dynamic> metadata, {
    String? prompt,
    String? model,
  }) {
    var loadedCount = loadParamJson(metadata);
    final positive = prompt ?? _metadataBasePrompt(metadata);
    if (positive != null) {
      fixedProfile.rootPromptConfig = fixedPromptConfig(positive);
      loadedCount++;
    }
    final characters = _metadataCharacters(metadata);
    if (characters != null) {
      fixedProfile.characterConfigList = characters;
      loadedCount += characters.length;
    }
    if (model != null && model.isNotEmpty) {
      fixedProfile.paramConfig.model = model;
      loadedCount++;
    }
    promptMode = PromptMode.fixed;
    return loadedCount;
  }

  MetadataImportAvailability metadataImportAvailability(
    Map<String, dynamic> metadata, {
    String? prompt,
    String? model,
  }) {
    final characters = _metadataCharacters(metadata);
    final settingsJson = _metadataSettingsJson(metadata, model: model);
    final settingsProbe =
        ParamConfig.fromJson(fixedProfile.paramConfig.toJson());
    final settingsCount = settingsProbe.loadJson(settingsJson);
    return MetadataImportAvailability(
      prompt: (prompt ?? _metadataBasePrompt(metadata)) != null,
      undesiredContent: _metadataNegativePrompt(metadata) != null,
      characters: characters != null && characters.isNotEmpty,
      settings: settingsCount > 0,
      seed: metadata['seed'] is num || metadata['random_seed'] is bool,
    );
  }

  int importMetadataSelectively(
    Map<String, dynamic> metadata, {
    String? prompt,
    String? model,
    required MetadataImportOptions options,
  }) {
    final working = fixedProfile.copy();
    var loadedCount = 0;

    if (options.prompt) {
      final imported = prompt ?? _metadataBasePrompt(metadata);
      if (imported != null) {
        final next = _prepareImportedPrompt(imported, options.cleanImports);
        final value = options.append
            ? _appendPromptText(_plainPrompt(working.rootPromptConfig), next)
            : next;
        working.rootPromptConfig = fixedPromptConfig(value);
        loadedCount++;
      }
    }

    if (options.undesiredContent) {
      final imported = _metadataNegativePrompt(metadata);
      if (imported != null) {
        final next = _prepareImportedPrompt(imported, options.cleanImports);
        final value = options.append
            ? _appendPromptText(
                _plainPrompt(working.negativePromptConfig),
                next,
              )
            : next;
        working.negativePromptConfig = fixedPromptConfig(
          value,
          negative: true,
        );
        working.paramConfig.negativePrompt = value;
        loadedCount++;
      }
    }

    if (options.characters) {
      final imported = _metadataCharacters(metadata);
      if (imported != null && imported.isNotEmpty) {
        if (options.cleanImports) {
          for (final character in imported) {
            character.positivePromptConfig = fixedPromptConfig(
              _prepareImportedPrompt(
                _plainPrompt(character.positivePromptConfig),
                true,
              ),
            );
            character.negativePromptConfig = fixedPromptConfig(
              _prepareImportedPrompt(
                _plainPrompt(character.negativePromptConfig),
                true,
              ),
              negative: true,
            );
          }
        }
        if (options.append) {
          working.characterConfigList.addAll(imported);
        } else {
          working.characterConfigList = imported;
        }
        final v4Prompt = metadata['v4_prompt'];
        if (v4Prompt is Map && v4Prompt['use_coords'] is bool) {
          working.paramConfig.autoPosition = !(v4Prompt['use_coords'] as bool);
        }
        loadedCount += imported.length;
      }
    }

    if (options.settings) {
      loadedCount += working.paramConfig.loadJson(
        _metadataSettingsJson(metadata, model: model),
      );
    }

    if (options.seed) {
      final seedJson = <String, dynamic>{};
      if (metadata['seed'] is num) {
        seedJson['seed'] = metadata['seed'];
      } else if (metadata['random_seed'] is bool) {
        seedJson['random_seed'] = metadata['random_seed'];
      }
      loadedCount += working.paramConfig.loadJson(seedJson);
    }

    if (loadedCount == 0) return 0;
    fixedProfile = working;
    promptMode = PromptMode.fixed;
    return loadedCount;
  }

  void switchPromptMode() {
    promptMode =
        promptMode == PromptMode.random ? PromptMode.fixed : PromptMode.random;
  }

  static PromptMode _promptModeFromJson(Map<String, dynamic> json) {
    if (json['prompt_mode'] == PromptMode.fixed.name) return PromptMode.fixed;
    if (json['prompt_mode'] == PromptMode.random.name) return PromptMode.random;
    return json['use_override_prompt'] == true
        ? PromptMode.fixed
        : PromptMode.random;
  }

  static PromptConfig fixedPromptConfig(String value, {bool negative = false}) {
    return PromptConfig(
      selectionMethod: 'all',
      shuffled: false,
      comment: negative ? '负面内容' : '提示词',
      strs: value.isEmpty ? [] : [value],
      prompts: [],
    );
  }

  static String _plainPrompt(PromptConfig config) {
    if (config.strs.isNotEmpty) return config.strs.first;
    return '';
  }

  static String? _metadataBasePrompt(Map<String, dynamic> json) {
    final v4 = json['v4_prompt'];
    if (v4 is Map) {
      final caption = v4['caption'];
      if (caption is Map && caption['base_caption'] is String) {
        return caption['base_caption'] as String;
      }
    }
    final input = json['input'];
    return input is String ? input : null;
  }

  static String? _metadataNegativePrompt(Map<String, dynamic> json) {
    final v4 = json['v4_negative_prompt'];
    if (v4 is Map) {
      final caption = v4['caption'];
      if (caption is Map && caption['base_caption'] is String) {
        return caption['base_caption'] as String;
      }
    }
    final value = json['negative_prompt'] ?? json['uc'];
    return value is String ? value : null;
  }

  static const Set<String> _metadataSettingKeys = {
    'sizes',
    'width',
    'height',
    'scale',
    'sampler',
    'steps',
    'n_samples',
    'ucPreset',
    'qualityToggle',
    'sm',
    'sm_dyn',
    'dynamic_thresholding',
    'controlnet_strength',
    'legacy',
    'add_original_image',
    'uncond_scale',
    'cfg_rescale',
    'noise_schedule',
    'deliberate_euler_ancestral_bug',
    'prefer_brownian',
    'straight_alpha',
    'tag_hint_qt',
    'tag_hint_uc_preset',
    'tag_hint_transparent_background',
    'variety_plus',
    'legacy_uc',
    'auto_position',
  };

  static Map<String, dynamic> _metadataSettingsJson(
    Map<String, dynamic> metadata, {
    String? model,
  }) {
    final result = <String, dynamic>{};
    for (final key in _metadataSettingKeys) {
      final value = metadata[key];
      if (key == 'sizes' && value is List) {
        final sizes = value
            .whereType<Map>()
            .where(
              (entry) => entry['width'] is num && entry['height'] is num,
            )
            .map(
              (entry) => <String, dynamic>{
                'width': entry['width'],
                'height': entry['height'],
              },
            )
            .toList(growable: false);
        if (sizes.isNotEmpty) result[key] = sizes;
        continue;
      }
      if (_isValidMetadataSetting(key, value)) result[key] = value;
    }
    if (model != null && model.isNotEmpty) result['model'] = model;
    return result;
  }

  static bool _isValidMetadataSetting(String key, Object? value) {
    if (value == null) return false;
    if (const {'sampler', 'noise_schedule'}.contains(key)) {
      return value is String;
    }
    if (const {
      'width',
      'height',
      'scale',
      'steps',
      'n_samples',
      'ucPreset',
      'controlnet_strength',
      'uncond_scale',
      'cfg_rescale',
      'tag_hint_qt',
      'tag_hint_uc_preset',
    }.contains(key)) {
      return value is num;
    }
    return value is bool;
  }

  static String _prepareImportedPrompt(String value, bool cleanImports) {
    if (!cleanImports) return value;
    return value
        .replaceAll(RegExp(r'[\[\]{}]'), '')
        .replaceAll(RegExp(r',\s*'), ', ')
        .trim();
  }

  static String _appendPromptText(String existing, String imported) {
    final left = existing.trim().replaceFirst(RegExp(r'[,\s]+$'), '');
    final right = imported.trim().replaceFirst(RegExp(r'^[,\s]+'), '');
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    return '$left, $right';
  }

  static List<CharacterConfig>? _metadataCharacters(Map<String, dynamic> json) {
    final v4Prompt = json['v4_prompt'];
    final v4Negative = json['v4_negative_prompt'];
    List<dynamic>? positives;
    List<dynamic>? negatives;
    if (v4Prompt is Map && v4Prompt['caption'] is Map) {
      final value = (v4Prompt['caption'] as Map)['char_captions'];
      if (value is List) positives = value;
    }
    if (v4Negative is Map && v4Negative['caption'] is Map) {
      final value = (v4Negative['caption'] as Map)['char_captions'];
      if (value is List) negatives = value;
    }
    final legacyCharacters = json['characterPrompts'];
    if (positives == null && legacyCharacters is List) {
      positives = legacyCharacters;
    }
    if (positives == null) return null;
    // V5 free-positioning metadata stores the character as a continuous
    // normalized point; preserve it as freeCenter instead of quantizing to a
    // legacy grid cell so the point lands back on the free canvas. V4 also
    // carries use_coords:true but with quantized grid centers, so it must keep
    // using the legacy grid position.
    final v5 = _isV5Metadata(json);
    final useCoords = v5 && v4Prompt is Map && v4Prompt['use_coords'] == true;
    final result = <CharacterConfig>[];
    for (final (index, raw) in positives.indexed) {
      if (raw is! Map) continue;
      final positive =
          raw['char_caption'] ?? raw['prompt'] ?? raw['caption'] ?? '';
      final negativeRaw =
          index < (negatives?.length ?? 0) ? negatives![index] : null;
      final negative = negativeRaw is Map
          ? negativeRaw['char_caption'] ??
              negativeRaw['uc'] ??
              negativeRaw['caption'] ??
              ''
          : raw['uc'] ?? '';
      final centerRaw =
          raw['centers'] is List && (raw['centers'] as List).isNotEmpty
              ? (raw['centers'] as List).first
              : raw['center'];
      result.add(
        CharacterConfig(
          positions: useCoords ? [] : [_positionFromMetadata(centerRaw)],
          freeCenter: useCoords ? _freeCenterFromMetadata(centerRaw) : null,
          positivePromptConfig: fixedPromptConfig(positive.toString()),
          negativePromptConfig: fixedPromptConfig(
            negative.toString(),
            negative: true,
          ),
          gender: CharacterConfig.genderUnset,
          enabled: true,
        ),
      );
    }
    return result;
  }

  static Point<int> _positionFromMetadata(dynamic raw) {
    if (raw is! Map) return CharacterConfig.defaultPosition;
    int nearest(dynamic value) {
      final number = value is num ? value.toDouble() : 0.5;
      var best = 3;
      var distance = double.infinity;
      for (final entry in doubleMapping.entries) {
        final candidate = (entry.value - number).abs();
        if (candidate < distance) {
          best = entry.key;
          distance = candidate;
        }
      }
      return best;
    }

    return Point<int>(nearest(raw['x']), nearest(raw['y']));
  }

  static bool _isV5Metadata(Map<String, dynamic> json) {
    final name = json['model_name'];
    if (name is String && name.contains('V5')) return true;
    if (json['model_hash'] == '0ADF9AB7') return true;
    return false;
  }

  static Point<double>? _freeCenterFromMetadata(dynamic raw) {
    if (raw is! Map) return null;
    final x = raw['x'];
    final y = raw['y'];
    if (x is! num || y is! num) return null;
    return Point<double>(
      x.toDouble().clamp(0.0, 1.0),
      y.toDouble().clamp(0.0, 1.0),
    );
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

  static PromptConfig _negativePromptConfigFromJson(Map<String, dynamic> json) {
    final config = PromptConfig.fromJson(json);
    if (config.comment == '反向提示词') {
      config.comment = '负面内容';
    }
    return config;
  }
}
