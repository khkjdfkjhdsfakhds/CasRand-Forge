/// One NovelAI API token entry for multi-token concurrent generation.
class ApiTokenConfig {
  String label;
  String token;
  bool enabled;
  bool isPrimary;

  ApiTokenConfig({
    required this.label,
    required this.token,
    this.enabled = true,
    this.isPrimary = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'label': label,
      'token': token,
      'enabled': enabled,
      'is_primary': isPrimary,
    };
  }

  factory ApiTokenConfig.fromJson(Map<String, dynamic> json) {
    return ApiTokenConfig(
      label: json['label'] ?? '',
      token: json['token'] ?? '',
      enabled: json['enabled'] ?? true,
      isPrimary: json['is_primary'] ?? false,
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
