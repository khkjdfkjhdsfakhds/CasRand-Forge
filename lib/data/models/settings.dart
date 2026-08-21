import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:nai_casrand/core/constants/settings.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';

import '../../core/constants/defaults.dart';

const int maxParallelApiTokens = 6;

class Settings {
  // Don't show again
  String welcomeMessageVersion;

  // Display settings
  int generationPageColumnCount;
  String themeMode;

  /// Whether prompt fields should show the offline Danbooru completion popup.
  /// This is enabled by default for existing and new configurations.
  bool promptAutocompleteEnabled;

  /// Result display style: 'classic' (default) or 'waterfall'. The classic
  /// mode restores the 0.55-style grid with the prompt beside the image.
  String resultDisplayMode;

  /// Ordered main-navigation authority shared by phone and desktop.
  NavigationConfiguration navigation;

  /// Manual prompt-mode changes ask for confirmation unless the user opted
  /// out. Automatic metadata/Enhance activation still reports the new mode.
  bool confirmPromptModeSwitch;

  // API key configured on the main settings page. This remains authoritative.
  String apiKey;

  /// Ordered account list shown by the multi-token manager. The primary entry
  /// mirrors [apiKey], but keeps its own position and enabled state.
  List<ApiTokenConfig> apiTokens;

  /// Whether generation may use the enabled entries in [apiTokens]. When
  /// disabled, generation follows the legacy single-account path via [apiKey].
  bool parallelApiEnabled;

  /// Subscription tier of the active account (3 = Opus), refreshed from the
  /// balance query. Drives the "free under Opus" cost estimate.
  int subscriptionTier;

  /// Runtime-only verification state. It is deliberately not restored from a
  /// saved config because subscription status can expire between launches.
  bool subscriptionActive;
  bool subscriptionStatusKnown;

  // Output dir, for windows only
  String outputFolderPath;

  /// Whether desktop generations should publish a JPEG candidate in addition
  /// to the normal PNG/session artifact. This remains opt-in for safety.
  bool jpegStorageEnabled;

  /// Keep a permanent PNG next to the JPEG when desktop JPEG storage is on.
  bool retainOriginalPng;

  // Proxy settings
  String proxy;

  // Debug API path
  String debugApiPath;
  bool debugApiEnabled;

  // Image metadata erase
  bool metadataEraseEnabled;
  bool customMetadataEnabled;
  String customMetadataContent;

  // Generation scheduling
  int generationCount;
  int generationIntervalSec;

  bool rememberSequentialProgress;
  bool lockToAllCombinations;

  // File name prefix key
  String fileNamePrefixKey;

  Settings({
    required this.welcomeMessageVersion,
    required this.apiKey,
    required this.outputFolderPath,
    this.jpegStorageEnabled = false,
    this.retainOriginalPng = false,
    required this.proxy,
    required this.debugApiEnabled,
    required this.debugApiPath,
    required this.metadataEraseEnabled,
    required this.customMetadataEnabled,
    required this.customMetadataContent,
    required this.generationCount,
    required this.generationIntervalSec,
    required this.rememberSequentialProgress,
    this.lockToAllCombinations = false,
    required this.fileNamePrefixKey,
    required this.generationPageColumnCount,
    required this.themeMode,
    this.promptAutocompleteEnabled = true,
    this.resultDisplayMode = 'classic',
    NavigationConfiguration? navigation,
    this.confirmPromptModeSwitch = true,
    this.subscriptionTier = 0,
    this.subscriptionActive = false,
    this.subscriptionStatusKnown = false,
    this.parallelApiEnabled = false,
    List<ApiTokenConfig>? apiTokens,
  })  : navigation = navigation ?? NavigationConfiguration.fromJson({}),
        apiTokens = apiTokens ?? [] {
    normalizeApiTokens();
  }

  /// Tokens that generation should use, in user-defined priority order.
  List<ApiTokenConfig> get effectiveApiTokens {
    if (!parallelApiEnabled) {
      if (apiKey.trim().isEmpty) return const [];
      final primary = apiTokens.where((entry) => entry.isPrimary).firstOrNull;
      return [
        ApiTokenConfig(
          label: primary?.label ?? 'Main API',
          token: apiKey.trim(),
          enabled: true,
          isPrimary: true,
        ),
      ];
    }
    return apiTokens
        .where((entry) => entry.enabled && entry.token.isNotEmpty)
        .take(maxParallelApiTokens)
        .toList(growable: false);
  }

  /// Replaces the primary token in place when the main settings value changes.
  /// A matching additional entry is folded into the primary entry.
  void updatePrimaryApiKey(String value) {
    final nextToken = value.trim();
    final primaryIndex = apiTokens.indexWhere((entry) => entry.isPrimary);
    final previous = primaryIndex == -1 ? null : apiTokens[primaryIndex];
    final insertIndex = primaryIndex == -1 ? 0 : primaryIndex;
    if (primaryIndex != -1) apiTokens.removeAt(primaryIndex);
    apiTokens.removeWhere((entry) => entry.token.trim() == nextToken);
    apiKey = nextToken;
    if (nextToken.isNotEmpty) {
      apiTokens.insert(
        insertIndex.clamp(0, apiTokens.length),
        ApiTokenConfig(
          label: previous?.label ?? 'Main API',
          token: nextToken,
          enabled: previous?.enabled ?? true,
          isPrimary: true,
        ),
      );
    }
    normalizeApiTokens();
  }

  /// Repairs old configurations, removes duplicate token values, preserves the
  /// user's order, and guarantees at most one primary entry.
  void normalizeApiTokens() {
    apiKey = apiKey.trim();
    final oldPrimaryIndex = apiTokens.indexWhere((entry) => entry.isPrimary);
    final oldPrimary =
        oldPrimaryIndex == -1 ? null : apiTokens[oldPrimaryIndex];
    final normalized = <ApiTokenConfig>[];
    final seen = <String>{};
    for (final entry in apiTokens) {
      final token = entry.token.trim();
      if (token.isEmpty || !seen.add(token)) continue;
      normalized.add(
        ApiTokenConfig(
          label: entry.label.trim().isEmpty ? 'Token' : entry.label.trim(),
          token: token,
          enabled: entry.enabled,
          isPrimary: false,
        ),
      );
    }

    if (apiKey.isNotEmpty) {
      final matchingIndex = normalized.indexWhere(
        (entry) => entry.token == apiKey,
      );
      if (matchingIndex != -1) {
        normalized[matchingIndex].isPrimary = true;
      } else {
        normalized.insert(
          oldPrimaryIndex == -1
              ? 0
              : oldPrimaryIndex.clamp(0, normalized.length),
          ApiTokenConfig(
            label: oldPrimary?.label ?? 'Main API',
            token: apiKey,
            enabled: oldPrimary?.enabled ?? true,
            isPrimary: true,
          ),
        );
      }
    }

    var enabledCount = 0;
    for (final entry in normalized) {
      if (!entry.enabled) continue;
      enabledCount++;
      if (enabledCount > maxParallelApiTokens) entry.enabled = false;
    }
    apiTokens
      ..clear()
      ..addAll(normalized);
    if (!apiTokens.any((entry) => entry.enabled)) {
      parallelApiEnabled = false;
    }
  }

  factory Settings.fromJson(Map<String, dynamic> json) {
    final tokenListJson = json['api_tokens'];
    final apiTokens = tokenListJson is List
        ? tokenListJson
            .whereType<Map<String, dynamic>>()
            .map(ApiTokenConfig.fromJson)
            .toList()
        : <ApiTokenConfig>[];
    final apiKey = (json['api_key'] ?? 'pst-abcd') as String;
    final hasEnabledAdditionalToken = apiTokens.any(
      (entry) =>
          entry.enabled &&
          entry.token.trim().isNotEmpty &&
          entry.token != apiKey,
    );
    return Settings(
      welcomeMessageVersion: json['welcome_message_version'] ?? '',
      apiKey: apiKey,
      apiTokens: apiTokens,
      parallelApiEnabled:
          json['parallel_api_enabled'] ?? hasEnabledAdditionalToken,
      resultDisplayMode: json['classic_grid_default_migrated'] == true
          ? (json['result_display_mode'] == 'waterfall'
              ? 'waterfall'
              : 'classic')
          : 'classic',
      navigation: NavigationConfiguration.fromJson(json),
      confirmPromptModeSwitch: json['confirm_prompt_mode_switch'] ?? true,
      subscriptionTier: json['subscription_tier'] ?? 0,
      outputFolderPath: json['output_folder'] ?? '',
      jpegStorageEnabled: json['jpeg_storage_enabled'] ?? false,
      retainOriginalPng: json['retain_original_png'] ?? false,
      proxy: json['proxy'] ?? '',
      debugApiEnabled: false,
      debugApiPath: 'http://localhost:5000/ai/generate-image',
      metadataEraseEnabled: json['metadata_erase_enabled'] ?? false,
      customMetadataEnabled: json['custom_metadata_enabled'] ?? false,
      customMetadataContent:
          json['custom_metadata_content'] ?? defaultWatermarkContent,
      generationCount:
          json['generation_count'] ?? json['number_of_requests'] ?? 0,
      generationIntervalSec:
          json['generation_interval'] ?? json['batch_interval'] ?? 2,
      rememberSequentialProgress: json['remember_sequential_progress'] ?? false,
      lockToAllCombinations: json['lock_to_all_combinations'] ?? false,
      fileNamePrefixKey: json['file_name_prefix_key'] ?? '',
      generationPageColumnCount: json['generation_page_column_count'] ?? 2,
      themeMode: json['theme_mode'] ?? 'system',
      promptAutocompleteEnabled: json['prompt_autocomplete_enabled'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'welcome_message_version': welcomeMessageVersion,
      'api_key': apiKey,
      'api_tokens': apiTokens.map((entry) => entry.toJson()).toList(),
      'parallel_api_enabled': parallelApiEnabled,
      'result_display_mode': resultDisplayMode,
      'classic_grid_default_migrated': true,
      ...navigation.toJson(),
      'confirm_prompt_mode_switch': confirmPromptModeSwitch,
      'subscription_tier': subscriptionTier,
      'output_folder': outputFolderPath,
      'jpeg_storage_enabled': jpegStorageEnabled,
      'retain_original_png': retainOriginalPng,
      'proxy': proxy,
      'metadata_erase_enabled': metadataEraseEnabled,
      'custom_metadata_enabled': customMetadataEnabled,
      'custom_metadata_content': customMetadataContent,
      'file_name_prefix_key': fileNamePrefixKey,
      'generation_count': generationCount,
      'generation_interval': generationIntervalSec,
      'remember_sequential_progress': rememberSequentialProgress,
      'lock_to_all_combinations': lockToAllCombinations,
      'generation_page_column_count': generationPageColumnCount,
      'theme_mode': themeMode,
      'prompt_autocomplete_enabled': promptAutocompleteEnabled,
    };
  }

  AdaptiveThemeMode get theme =>
      stringToThemeMode[themeMode] ?? AdaptiveThemeMode.system;
}
