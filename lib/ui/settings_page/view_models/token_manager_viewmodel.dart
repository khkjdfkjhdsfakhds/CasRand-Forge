import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/config_service.dart';

class TokenManagerViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  List<ApiTokenConfig> get tokens => payloadConfig.settings.apiTokens;

  /// Balance per token value; null = query failed, absent = not queried yet.
  final Map<String, int?> balances = {};
  final Set<String> _loadingTokens = {};

  bool isBalanceLoading(String token) => _loadingTokens.contains(token);

  void addToken(String label, String token) {
    final trimmedToken = token.trim();
    if (trimmedToken.isEmpty) return;
    final effectiveLabel =
        label.trim().isEmpty ? 'Token ${tokens.length + 1}' : label.trim();
    tokens.add(ApiTokenConfig(
      label: effectiveLabel,
      token: trimmedToken,
      enabled: true,
    ));
    _persist();
    refreshBalance(trimmedToken);
  }

  void removeTokenAt(int index) {
    if (index < 0 || index >= tokens.length) return;
    tokens.removeAt(index);
    _persist();
  }

  void setTokenEnabled(int index, bool enabled) {
    if (index < 0 || index >= tokens.length) return;
    tokens[index].enabled = enabled;
    _persist();
  }

  void renameToken(int index, String label) {
    if (index < 0 || index >= tokens.length) return;
    if (label.trim().isEmpty) return;
    tokens[index].label = label.trim();
    _persist();
  }

  /// Imports the legacy single API key as the first token entry.
  void importLegacyApiKey() {
    final legacy = payloadConfig.settings.apiKey;
    if (legacy.isEmpty) return;
    if (tokens.any((entry) => entry.token == legacy)) return;
    tokens.add(ApiTokenConfig(
      label: 'Token ${tokens.length + 1}',
      token: legacy,
      enabled: true,
    ));
    _persist();
    refreshBalance(legacy);
  }

  Future<void> refreshBalance(String token) async {
    if (token.isEmpty || _loadingTokens.contains(token)) return;
    _loadingTokens.add(token);
    notifyListeners();
    final balance = await AccountService().fetchAnlasBalance(
      token: token,
      proxy: payloadConfig.settings.proxy,
    );
    _loadingTokens.remove(token);
    balances[token] = balance;
    notifyListeners();
  }

  Future<void> refreshAllBalances() async {
    final targets = tokens
        .where((entry) => entry.token.isNotEmpty)
        .map((entry) => entry.token)
        .toSet();
    await Future.wait(targets.map(refreshBalance));
  }

  void _persist() {
    payloadConfig.settings.syncLegacyApiKey();
    GetIt.I<ConfigService>().saveConfig(payloadConfig.toJson());
    notifyListeners();
  }
}
