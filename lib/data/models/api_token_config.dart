/// One NovelAI API token entry for multi-token concurrent generation.
class ApiTokenConfig {
  static const int maxConcurrency = 4;

  String label;
  String token;
  bool enabled;
  bool isPrimary;
  bool allowPoints;
  bool allowFree;
  String apiBaseUrl;
  int concurrency;

  ApiTokenConfig({
    required this.label,
    required this.token,
    this.enabled = true,
    this.isPrimary = false,
    this.allowPoints = true,
    this.allowFree = true,
    this.apiBaseUrl = 'https://image.novelai.net',
    int concurrency = 1,
  }) : concurrency = concurrency.clamp(1, maxConcurrency).toInt();

  Map<String, dynamic> toJson() {
    return {
      'label': label,
      'token': token,
      'enabled': enabled,
      'is_primary': isPrimary,
      'allow_points': allowPoints,
      'allow_free': allowFree,
      'api_base_url': apiBaseUrl,
      'concurrency': concurrency,
    };
  }

  factory ApiTokenConfig.fromJson(Map<String, dynamic> json) {
    final apiBaseUrl = json['api_base_url'] ?? 'https://image.novelai.net';
    final storedConcurrency = json['concurrency'];
    final parsedConcurrency = storedConcurrency is int
        ? storedConcurrency
        : int.tryParse('$storedConcurrency');
    final inferredConcurrency =
        Uri.tryParse(apiBaseUrl as String)?.host == 'api.takoma.app'
            ? maxConcurrency
            : 1;
    return ApiTokenConfig(
      label: json['label'] ?? '',
      token: json['token'] ?? '',
      enabled: json['enabled'] ?? true,
      isPrimary: json['is_primary'] ?? false,
      allowPoints: json['allow_points'] ?? true,
      allowFree: json['allow_free'] ?? true,
      apiBaseUrl: apiBaseUrl,
      concurrency: parsedConcurrency ?? inferredConcurrency,
    );
  }

  /// Masked display form: keeps a short prefix/suffix, hides the middle.
  String get maskedToken {
    if (token.isEmpty) return '';
    if (token.length <= 10) {
      final visibleLength = token.length.clamp(1, 2);
      return '${token.substring(0, visibleLength)}···';
    }
    return '${token.substring(0, 6)}···${token.substring(token.length - 4)}';
  }
}
