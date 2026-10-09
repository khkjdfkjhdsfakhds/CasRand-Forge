import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:nai_casrand/core/constants/settings.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';

const int maxParallelApiTokens = 6;

/// How generated images are written to the output folder.
///
/// [webp] asks NovelAI itself for its official lossless WebP (the same file the
/// website saves); the JPEG choices are encoded locally on desktop.
enum GeneratedImageSaveFormat {
  png('png'),
  webp('webp'),
  jpegWithMetadata('jpeg'),
  jpegWithoutMetadata('jpeg_no_metadata');

  const GeneratedImageSaveFormat(this.jsonValue);

  final String jsonValue;

  bool get isJpeg => this == jpegWithMetadata || this == jpegWithoutMetadata;

  static GeneratedImageSaveFormat? fromJsonValue(Object? value) {
    for (final format in values) {
      if (format.jsonValue == value) return format;
    }
    return null;
  }

  /// Configurations saved before the format selector stored a JPEG switch
  /// and a separate metadata-erase switch; map them onto the closest choice.
  static GeneratedImageSaveFormat fromJson(Map<String, dynamic> json) {
    final stored = fromJsonValue(json['image_save_format']);
    if (stored != null) return stored;
    if (json['jpeg_storage_enabled'] != true) return png;
    return json['metadata_erase_enabled'] == true
        ? jpegWithoutMetadata
        : jpegWithMetadata;
  }
}

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
  /// disabled, generation normally follows the legacy single-account path via
  /// [apiKey], except when the main account is disabled and exactly one listed
  /// account remains enabled.
  bool parallelApiEnabled;

  /// Subscription tier of the active account (3 = Opus), refreshed from the
  /// balance query. Drives the "free under Opus" cost estimate.
  int subscriptionTier;

  /// Runtime-only verification state. It is deliberately not restored from a
  /// saved config because subscription status can expire between launches.
  bool subscriptionActive;
  bool subscriptionStatusKnown;

  /// Runtime-only V5 quota availability from the latest subscription
  /// snapshot. Null means the server has not supplied usage information yet.
  bool? opusUsageAvailable;

  // Output dir, for windows only
  String outputFolderPath;

  /// Output format for generated images. JPEG choices are desktop-only and
  /// fall back to PNG elsewhere.
  GeneratedImageSaveFormat imageSaveFormat;

  /// Keep a permanent PNG next to the JPEG when a JPEG format is selected.
  bool retainOriginalPng;

  // Proxy settings
  String proxy;

  /// API service base URL. NovelAI's image API remains the default; compatible
  /// relays such as Takoma can be selected without changing token handling.
  String apiBaseUrl;

  // Debug API path
  String debugApiPath;
  bool debugApiEnabled;

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
    this.imageSaveFormat = GeneratedImageSaveFormat.png,
    this.retainOriginalPng = false,
    required this.proxy,
    this.apiBaseUrl = officialApiBaseUrl,
    required this.debugApiEnabled,
    required this.debugApiPath,
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
    this.opusUsageAvailable,
    this.parallelApiEnabled = false,
    List<ApiTokenConfig>? apiTokens,
  })  : navigation = navigation ?? NavigationConfiguration.fromJson({}),
        apiTokens = apiTokens ?? [] {
    normalizeApiTokens();
  }

  static const String officialApiBaseUrl = 'https://image.novelai.net';
  static const String takomaApiHost = 'api.takoma.app';
  static const String takomaApiBaseUrl = 'https://$takomaApiHost';

  String get normalizedApiBaseUrl {
    final value = apiBaseUrl.trim();
    if (value.isEmpty) return officialApiBaseUrl;
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  bool get isTakomaApi =>
      Uri.tryParse(normalizedApiBaseUrl)?.host == takomaApiHost;

  String apiBaseUrlForToken(String token) {
    final entry = apiTokens
        .where((item) => item.token.trim() == token.trim())
        .firstOrNull;
    final value = entry?.apiBaseUrl.trim() ?? normalizedApiBaseUrl;
    if (value.isEmpty) return officialApiBaseUrl;
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  bool isTakomaToken(String token) =>
      Uri.tryParse(apiBaseUrlForToken(token))?.host == takomaApiHost;

  String apiEndpointForToken(String token, String path) {
    final base = apiBaseUrlForToken(token);
    return '$base/${path.replaceFirst('/', '')}';
  }

  String apiEndpoint(String path) =>
      '$normalizedApiBaseUrl/${path.replaceFirst('/', '')}';

  /// Tokens that generation should use, in user-defined priority order.
  List<ApiTokenConfig> get effectiveApiTokens {
    final enabledTokens = apiTokens
        .where((entry) => entry.enabled && entry.token.isNotEmpty)
        .take(maxParallelApiTokens)
        .toList(growable: false);
    if (!parallelApiEnabled) {
      final primaryEntry =
          apiTokens.where((entry) => entry.isPrimary).firstOrNull;
      // If the main account was disabled and one listed account remains
      // enabled, honor that selection instead of falling back to the disabled
      // main token configured on the parent settings page.
      if (enabledTokens.length == 1 && primaryEntry?.enabled == false) {
        return enabledTokens;
      }

      var primary = apiTokens.where((entry) => entry.isPrimary).firstOrNull;
      primary ??= apiTokens
          .where((entry) => entry.enabled && entry.token.isNotEmpty)
          .firstOrNull;
      primary ??=
          apiTokens.where((entry) => entry.token.isNotEmpty).firstOrNull;

      final effectiveToken = apiKey.trim().isNotEmpty
          ? apiKey.trim()
          : (primary?.token.trim() ?? '');
      if (effectiveToken.isEmpty) return const [];
      return [
        ApiTokenConfig(
          label: primary?.label ?? 'Main API',
          token: effectiveToken,
          enabled: true,
          isPrimary: true,
          allowPoints: primary?.allowPoints ?? true,
          allowFree: primary?.allowFree ?? true,
          apiBaseUrl: primary?.apiBaseUrl ?? normalizedApiBaseUrl,
        ),
      ];
    }
    return enabledTokens;
  }

  /// Whether the specified token is allowed to spend Anlas points.
  /// Defaults to true if the token is not found in [apiTokens].
  bool allowsPointsForToken(String token) {
    final trimmed = token.trim();
    final entry = apiTokens.where((e) => e.token.trim() == trimmed).firstOrNull;
    return entry?.allowPoints ?? true;
  }

  /// Whether the specified token is allowed to use free Opus allowance.
  /// Defaults to true if the token is not found in [apiTokens].
  bool allowsFreeForToken(String token) {
    final trimmed = token.trim();
    final entry = apiTokens.where((e) => e.token.trim() == trimmed).firstOrNull;
    return entry?.allowFree ?? true;
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
          allowPoints: previous?.allowPoints ?? true,
          allowFree: previous?.allowFree ?? true,
          apiBaseUrl: previous?.apiBaseUrl ?? normalizedApiBaseUrl,
          concurrency: previous?.concurrency ?? 1,
        ),
      );
    }
    normalizeApiTokens();
  }

  /// Repairs old configurations, removes duplicate token values, preserves the
  /// user's order, and guarantees at most one primary entry.
  void normalizeApiTokens() {
    apiKey = apiKey.trim();
    final normalized = <ApiTokenConfig>[];
    ApiTokenConfig? oldPrimary;
    var oldPrimaryIndex = -1;

    for (final (index, entry) in apiTokens.indexed) {
      if (entry.isPrimary) {
        oldPrimary ??= entry;
        if (oldPrimaryIndex == -1) oldPrimaryIndex = index;
      }
    }

    for (final entry in apiTokens) {
      final token = entry.token.trim();
      if (token.isEmpty) continue;
      if (normalized.any((existing) => existing.token == token)) continue;
      final isPrimary = entry.isPrimary ||
          (oldPrimary == null && token == apiKey && apiKey.isNotEmpty);
      normalized.add(ApiTokenConfig(
        label: entry.label,
        token: token,
        enabled: entry.enabled,
        isPrimary: isPrimary,
        allowPoints: entry.allowPoints,
        allowFree: entry.allowFree,
        apiBaseUrl: entry.apiBaseUrl,
        concurrency: entry.concurrency,
      ));
    }

    if (apiKey.isNotEmpty) {
      final primaryInList =
          normalized.where((entry) => entry.token == apiKey).firstOrNull;
      if (primaryInList != null) {
        primaryInList.isPrimary = true;
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
            allowPoints: oldPrimary?.allowPoints ?? true,
            allowFree: oldPrimary?.allowFree ?? true,
            apiBaseUrl: oldPrimary?.apiBaseUrl ?? normalizedApiBaseUrl,
          ),
        );
      }
    } else if (normalized.isNotEmpty) {
      final existingPrimary =
          normalized.where((entry) => entry.isPrimary).firstOrNull;
      if (existingPrimary != null) {
        apiKey = existingPrimary.token;
      } else {
        final candidate =
            normalized.where((entry) => entry.enabled).firstOrNull ??
                normalized.first;
        candidate.isPrimary = true;
        apiKey = candidate.token;
      }
    }

    var foundPrimary = false;
    for (final entry in normalized) {
      if (entry.isPrimary) {
        if (!foundPrimary && (apiKey.isEmpty || entry.token == apiKey)) {
          foundPrimary = true;
        } else {
          entry.isPrimary = false;
        }
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
    final legacyBase = json['api_base_url'] as String?;
    if (legacyBase != null && apiTokens.isNotEmpty) {
      final primary = apiTokens.where((entry) => entry.isPrimary).firstOrNull;
      if (primary != null && primary.apiBaseUrl == officialApiBaseUrl) {
        primary.apiBaseUrl = legacyBase;
      }
    }
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
      imageSaveFormat: GeneratedImageSaveFormat.fromJson(json),
      retainOriginalPng: json['retain_original_png'] ?? false,
      proxy: json['proxy'] ?? '',
      apiBaseUrl: json['api_base_url'] ?? officialApiBaseUrl,
      debugApiEnabled: false,
      debugApiPath: 'http://localhost:5000/ai/generate-image',
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
      'image_save_format': imageSaveFormat.jsonValue,
      'retain_original_png': retainOriginalPng,
      'proxy': proxy,
      'api_base_url': normalizedApiBaseUrl,
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
