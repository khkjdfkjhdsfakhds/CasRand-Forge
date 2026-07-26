import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:nai_casrand/core/constants/settings.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';

import '../../core/constants/defaults.dart';

class Settings {
  // Don't show again
  String welcomeMessageVersion;

  // Display settings
  int generationPageColumnCount;
  String themeMode;

  /// Result display style: 'waterfall' (default) or 'classic' (0.55-style
  /// grid with the prompt shown beside the image).
  String resultDisplayMode;

  // API key (legacy single-token field, kept in sync with [apiTokens])
  String apiKey;

  /// Multi-token support. Empty list means "use [apiKey] only".
  List<ApiTokenConfig> apiTokens;

  // Output dir, for windows only
  String outputFolderPath;

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

  // File name prefix key
  String fileNamePrefixKey;

  Settings({
    required this.welcomeMessageVersion,
    required this.apiKey,
    required this.outputFolderPath,
    required this.proxy,
    required this.debugApiEnabled,
    required this.debugApiPath,
    required this.metadataEraseEnabled,
    required this.customMetadataEnabled,
    required this.customMetadataContent,
    required this.generationCount,
    required this.generationIntervalSec,
    required this.rememberSequentialProgress,
    required this.fileNamePrefixKey,
    required this.generationPageColumnCount,
    required this.themeMode,
    this.resultDisplayMode = 'waterfall',
    List<ApiTokenConfig>? apiTokens,
  }) : apiTokens = apiTokens ?? [];

  /// Tokens that generation should use, in order. Falls back to the legacy
  /// [apiKey] when no explicit token entries exist.
  List<ApiTokenConfig> get effectiveApiTokens {
    final active = apiTokens
        .where((entry) => entry.enabled && entry.token.isNotEmpty)
        .toList(growable: false);
    if (active.isNotEmpty) return active;
    return [ApiTokenConfig(label: 'Token 1', token: apiKey, enabled: true)];
  }

  /// Keeps the legacy single-token field aligned with the token list so old
  /// exports and older app versions stay compatible.
  void syncLegacyApiKey() {
    final active = apiTokens
        .where((entry) => entry.enabled && entry.token.isNotEmpty)
        .toList(growable: false);
    if (active.isNotEmpty) {
      apiKey = active.first.token;
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
    return Settings(
      welcomeMessageVersion: json['welcome_message_version'] ?? '',
      apiKey: json['api_key'] ?? 'pst-abcd',
      apiTokens: apiTokens,
      resultDisplayMode: json['result_display_mode'] ?? 'waterfall',
      outputFolderPath: json['output_folder'] ?? '',
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
          json['generation_interval'] ?? json['batch_interval'] ?? 10,
      rememberSequentialProgress: json['remember_sequential_progress'] ?? false,
      fileNamePrefixKey: json['file_name_prefix_key'] ?? '',
      generationPageColumnCount: json['generation_page_column_count'] ?? 2,
      themeMode: json['theme_mode'] ?? 'system',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'welcome_message_version': welcomeMessageVersion,
      'api_key': apiKey,
      'api_tokens': apiTokens.map((entry) => entry.toJson()).toList(),
      'result_display_mode': resultDisplayMode,
      'output_folder': outputFolderPath,
      'proxy': proxy,
      'metadata_erase_enabled': metadataEraseEnabled,
      'custom_metadata_enabled': customMetadataEnabled,
      'custom_metadata_content': customMetadataContent,
      'file_name_prefix_key': fileNamePrefixKey,
      'generation_count': generationCount,
      'generation_interval': generationIntervalSec,
      'remember_sequential_progress': rememberSequentialProgress,
      'generation_page_column_count': generationPageColumnCount,
      'theme_mode': themeMode,
    };
  }

  AdaptiveThemeMode get theme =>
      stringToThemeMode[themeMode] ?? AdaptiveThemeMode.system;
}
