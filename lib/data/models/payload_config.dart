import 'dart:math';

import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';

import 'package:flutter/foundation.dart';
import 'package:nai_casrand/core/constants/defaults.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';
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
import 'package:nai_casrand/data/use_cases/novelai_text_rendering.dart';

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

class PayloadConfig extends ChangeNotifier {
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
  // Prepared tool resources are transient, just like their source images.
  BatchToolSnapshot? enhanceBatchTool;
  BatchToolSnapshot? directorBatchTool;
  BatchToolKind? batchToolKind;
  BatchToolSnapshot? get activeBatchTool => switch (batchToolKind) {
        BatchToolKind.enhance => enhanceBatchTool,
        BatchToolKind.director => directorBatchTool,
        null => null,
      };

  void activateBatchTool(BatchToolSnapshot tool) {
    if (tool.kind == BatchToolKind.enhance) {
      enhanceBatchTool = tool;
    } else {
      directorBatchTool = tool;
    }
    batchToolKind = tool.kind;
    promptMode = PromptMode.fixed;
    notifyListeners();
  }

  void deactivateBatchTool() {
    batchToolKind = null;
    promptMode = PromptMode.random;
    notifyListeners();
  }

  bool i2iEnabled = false;
  bool vibeEnabled = false;
  bool preciseReferenceEnabled = false;
  bool _i2iManuallyDisabled = false;
  bool _vibeManuallyDisabled = false;
  bool _preciseReferenceManuallyDisabled = false;

  bool get hasVibeResources =>
      vibeConfigList.isNotEmpty || vibeConfigListV4.isNotEmpty;

  GenerationReferenceUsage get activeReferenceUsage {
    final capabilities = ImageImportCapabilities.forModel(paramConfig.model);
    return capabilities.resolveReferenceUsage(
      vibeEnabled: vibeEnabled,
      preciseReferenceEnabled: preciseReferenceEnabled,
      legacyVibeCount: vibeConfigList.length,
      modernVibeCount: vibeConfigListV4.length,
      preciseReferenceCount: preciseReferenceConfigList
          .where((reference) => reference.enabled)
          .length,
    );
  }

  /// V3 does not consume character captions. Counting and generation share
  /// this participation boundary so switching models does not consume hidden
  /// character progress.
  Iterable<CharacterConfig> get activeCharacterConfigs =>
      paramConfig.model.startsWith('nai-diffusion-4-') ||
              paramConfig.model.startsWith('nai-diffusion-5-')
          ? characterConfigList.where((char) => char.enabled)
          : const <CharacterConfig>[];

  BigInt get totalCombinationCycle {
    final filterEntryComments = promptMode != PromptMode.fixed;
    BigInt cycle(PromptConfig config, {bool filter = true}) =>
        config.calculateCombinationCycle(
          filterEntryComments: filter,
          savedConfigs: savedPromptConfigList,
        );
    return PromptConfig.combineCycles([
      cycle(rootPromptConfig, filter: filterEntryComments),
      cycle(negativePromptConfig, filter: filterEntryComments),
      for (final char in activeCharacterConfigs) ...[
        cycle(char.positivePromptConfig),
        cycle(char.negativePromptConfig),
      ],
    ]);
  }

  int? get totalCombinationTaskCount =>
      PromptConfig.taskCountForCycle(totalCombinationCycle);

  int get totalCombinations =>
      totalCombinationTaskCount ??
      (throw RangeError('Prompt cycle exceeds the task counter range'));

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
    enhanceBatchTool = null;
    directorBatchTool = null;
    batchToolKind = null;
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

  /// Configuration intended for sharing. Authentication remains local.
  Map<String, dynamic> toShareableJson() {
    final json = toJson();
    final settingsJson = Map<String, dynamic>.from(
      json['settings'] as Map<String, dynamic>? ?? const {},
    )
      ..remove('api_key')
      ..remove('api_tokens');
    json['settings'] = settingsJson;
    return json;
  }

  /// Loads a credential-free shared configuration without replacing this
  /// device's primary or additional NovelAI tokens.
  void loadShareableJson(Map<String, dynamic> jsonData) {
    final primary = settings.apiKey;
    final tokens = settings.apiTokens
        .map((entry) => ApiTokenConfig.fromJson(entry.toJson()))
        .toList(growable: false);
    final parallel = settings.parallelApiEnabled;
    loadJson(jsonData);
    settings.updatePrimaryApiKey(primary);
    settings.apiTokens
      ..clear()
      ..addAll(tokens);
    settings.parallelApiEnabled = parallel;
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
    enhanceBatchTool = null;
    directorBatchTool = null;
    batchToolKind = null;
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
    notifyListeners();
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
    final importedModel =
        model?.isNotEmpty == true ? model! : fixedProfile.paramConfig.model;
    fixedProfile.paramConfig = _metadataDefaultsForModel(importedModel);
    var loadedCount = fixedProfile.paramConfig.loadJson(
      _metadataSettingsJson(metadata, model: model),
    );
    final seedJson = _metadataSeedJson(metadata);
    loadedCount += fixedProfile.paramConfig.loadJson(seedJson);
    final negative = _metadataNegativePrompt(metadata);
    if (negative != null) {
      fixedProfile.negativePromptConfig = fixedPromptConfig(
        negative,
        negative: true,
      );
      fixedProfile.paramConfig.negativePrompt = negative;
      loadedCount++;
    } else {
      fixedProfile.negativePromptConfig = fixedPromptConfig(
        fixedProfile.paramConfig.negativePrompt,
        negative: true,
      );
    }
    final positive = prompt ?? _metadataBasePrompt(metadata);
    if (positive != null) {
      fixedProfile.rootPromptConfig = fixedPromptConfig(
        _normalizeImportedTextPrompt(
          positive,
          metadata,
          targetModel: fixedProfile.paramConfig.model,
        ),
      );
      loadedCount++;
    } else {
      fixedProfile.rootPromptConfig = fixedPromptConfig('');
    }
    final characters = _metadataCharacters(metadata, model: model);
    if (characters != null) {
      fixedProfile.characterConfigList = characters;
      loadedCount += max(1, characters.length);
    } else {
      fixedProfile.characterConfigList = [];
    }
    _disableTransientGenerationInputs();
    promptMode = PromptMode.fixed;
    notifyListeners();
    return loadedCount;
  }

  MetadataImportAvailability metadataImportAvailability(
    Map<String, dynamic> metadata, {
    String? prompt,
    String? model,
  }) {
    final settingsJson = _metadataSettingsJson(metadata, model: model);
    final settingsProbe =
        ParamConfig.fromJson(fixedProfile.paramConfig.toJson());
    final settingsCount = settingsProbe.loadJson(settingsJson);
    return MetadataImportAvailability(
      // A missing prompt in an otherwise valid generation record must be able
      // to clear stale fixed text instead of silently keeping it.
      prompt: metadata.isNotEmpty,
      // Missing categories in a valid generation record mean "use the model
      // default", not "keep unrelated values from the current profile".
      undesiredContent: metadata.isNotEmpty,
      // Empty or absent character metadata means there were no characters;
      // importing that category must clear stale characters in the profile.
      characters: metadata.isNotEmpty,
      settings: settingsCount > 0,
      seed: metadata.isNotEmpty,
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
      } else if (!options.append) {
        final modelDefaults =
            _metadataDefaultsForModel(model ?? working.paramConfig.model);
        working.negativePromptConfig = fixedPromptConfig(
          modelDefaults.negativePrompt,
          negative: true,
        );
        working.paramConfig.negativePrompt = modelDefaults.negativePrompt;
        loadedCount++;
      }
    }

    if (options.characters) {
      final imported = _metadataCharacters(metadata, model: model);
      if (imported != null) {
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
        // Count the category itself when the source explicitly contains an
        // empty character list; otherwise a characters-only clear would be
        // mistaken for a no-op and the dialog would reject the import.
        loadedCount += max(1, imported.length);
      } else if (!options.append) {
        working.characterConfigList = [];
        loadedCount++;
      }
    }

    if (options.settings) {
      final currentSeed = working.paramConfig.seed;
      final currentRandomSeed = working.paramConfig.randomSeed;
      final currentNegativePrompt = working.paramConfig.negativePrompt;
      final importedModel =
          model?.isNotEmpty == true ? model! : working.paramConfig.model;
      working.paramConfig = _metadataDefaultsForModel(
        importedModel,
        seed: currentSeed,
        randomSeed: currentRandomSeed,
        negativePrompt: currentNegativePrompt,
      );
      loadedCount += working.paramConfig.loadJson(
        _metadataSettingsJson(metadata, model: model),
      );
    }

    if (options.seed) {
      loadedCount += working.paramConfig.loadJson(_metadataSeedJson(metadata));
    }

    // Resolve the selected model first. Removing an automatic block would
    // lose conditioning if the user kept a model without automatic text.
    if (options.prompt) {
      final imported = prompt ?? _metadataBasePrompt(metadata);
      if (imported != null) {
        final normalized = _normalizeImportedTextPrompt(
          imported,
          metadata,
          targetModel: working.paramConfig.model,
          includeCharacters: options.characters,
        );
        final next = _prepareImportedPrompt(normalized, options.cleanImports);
        final value = options.append
            ? _appendPromptText(_plainPrompt(working.rootPromptConfig), next)
            : next;
        working.rootPromptConfig = fixedPromptConfig(value);
        loadedCount++;
      } else if (!options.append) {
        working.rootPromptConfig = fixedPromptConfig('');
        loadedCount++;
      }
    }

    if (loadedCount == 0) return 0;
    fixedProfile = working;
    if (options.settings) _disableTransientGenerationInputs();
    promptMode = PromptMode.fixed;
    notifyListeners();
    return loadedCount;
  }

  void _disableTransientGenerationInputs() {
    clearI2iResourceState();
    clearVibeResourceState();
    clearPreciseReferenceResourceState();
  }

  static ParamConfig _metadataDefaultsForModel(
    String model, {
    bool randomSeed = true,
    int? seed = 0,
    String? negativePrompt,
  }) {
    var scale = 5.0;
    if (model == 'nai-diffusion-5-full' || model == 'nai-diffusion-5-curated') {
      scale = 7.0;
    } else if (model == 'nai-diffusion-4-full' ||
        model == 'nai-diffusion-4-curated-preview') {
      scale = 5.5;
    } else if (model == 'nai-diffusion-furry-3') {
      scale = 6.2;
    }
    return ParamConfig(
      model: model,
      scale: scale,
      sampler: 'k_euler_ancestral',
      steps: 23,
      noiseSchedule: 'karras',
      sm: false,
      smDyn: false,
      randomSeed: randomSeed,
      seed: seed,
      negativePrompt: negativePrompt ?? defaultUC,
    );
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
    'quality_boost',
    'sm',
    'sm_dyn',
    'dynamic_thresholding',
    'controlnet_strength',
    'legacy',
    'legacy_v3_extend',
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
    'use_coords',
  };

  static const Set<String> _nullableMetadataSettingKeys = {
    'deliberate_euler_ancestral_bug',
    'prefer_brownian',
    'straight_alpha',
    'tag_hint_qt',
    'tag_hint_uc_preset',
    'tag_hint_transparent_background',
  };

  static Map<String, dynamic> _metadataSettingsJson(
    Map<String, dynamic> metadata, {
    String? model,
  }) {
    final result = <String, dynamic>{};
    for (final key in _metadataSettingKeys) {
      if (!metadata.containsKey(key)) continue;
      final value = metadata[key];
      if (value == null && _nullableMetadataSettingKeys.contains(key)) {
        result[key] = null;
        continue;
      }
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
    if (metadata.containsKey('quality_boost') &&
        metadata['quality_boost'] is bool) {
      result['qualityToggle'] = metadata['quality_boost'];
      result.remove('quality_boost');
    }
    // NovelAI stores Variety+ as the computed sigma threshold in generated
    // image metadata. A missing/null threshold means the switch was off. Keep
    // accepting the app's own explicit boolean for compatibility JSON.
    result['variety_plus'] = metadata.containsKey('skip_cfg_above_sigma')
        ? metadata['skip_cfg_above_sigma'] is num
        : metadata['variety_plus'] == true;
    final v4Prompt = metadata['v4_prompt'];
    if (v4Prompt is Map && v4Prompt['use_coords'] is bool) {
      result['auto_position'] = !(v4Prompt['use_coords'] as bool);
    }
    final v4NegativePrompt = metadata['v4_negative_prompt'];
    if (!result.containsKey('legacy_uc') &&
        v4NegativePrompt is Map &&
        v4NegativePrompt['legacy_uc'] is bool) {
      result['legacy_uc'] = v4NegativePrompt['legacy_uc'];
    }
    if (model != null && model.isNotEmpty) result['model'] = model;
    return result;
  }

  static Map<String, dynamic> _metadataSeedJson(
    Map<String, dynamic> metadata,
  ) {
    if (metadata['seed'] is num) return {'seed': metadata['seed']};
    if (metadata['random_seed'] is bool) {
      return {'random_seed': metadata['random_seed']};
    }
    // Generated images always represent one concrete seed. If it is absent,
    // do not inherit an unrelated fixed seed from the current profile.
    return const {'random_seed': true};
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

  static String _normalizeImportedTextPrompt(
    String value,
    Map<String, dynamic> metadata, {
    required String targetModel,
    bool includeCharacters = true,
  }) {
    if (!targetModel.contains('diffusion-5')) return value;
    final v4 = metadata['v4_prompt'];
    final caption = v4 is Map ? v4['caption'] : null;
    final rawCharacters = caption is Map ? caption['char_captions'] : null;
    final sourceCharacters = rawCharacters is List
        ? rawCharacters
        : metadata['characterPrompts'] is List
            ? metadata['characterPrompts'] as List
            : const [];
    final characters = <TextRenderingCharacter>[];
    for (final raw in sourceCharacters) {
      if (raw is! Map) continue;
      final prompt = raw['char_caption'] ?? raw['prompt'];
      if (prompt is! String) continue;
      final centers = raw['centers'];
      final point =
          centers is List && centers.isNotEmpty ? centers.first : raw['center'];
      final x = point is Map ? point['x'] : null;
      final y = point is Map ? point['y'] : null;
      characters.add(TextRenderingCharacter(
        prompt: prompt,
        center:
            Point(x is num ? x.toDouble() : .5, y is num ? y.toDouble() : .5),
      ));
    }
    final useCoords = v4 is Map && v4['use_coords'] == true;
    final normalized = NovelAiTextRendering.removeAutomaticBlock(
      value,
      characters,
      useCoords: useCoords,
    );
    if (normalized == value) return value;
    // A prompt-only selection must not silently discard dialogue whose only
    // source is an excluded character. Still verify against the full source
    // first, so a manual block cannot be misclassified by a partial selection.
    if (!includeCharacters &&
        NovelAiTextRendering.removeAutomaticBlock(
              value,
              const [],
              useCoords: useCoords,
            ) !=
            normalized) {
      return value;
    }
    return normalized;
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

  static List<CharacterConfig>? _metadataCharacters(
    Map<String, dynamic> json, {
    String? model,
  }) {
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
    final v5 = _isV5Metadata(json, model: model);
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

  static bool _isV5Metadata(Map<String, dynamic> json, {String? model}) {
    if (model?.contains('diffusion-5') == true) return true;
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
