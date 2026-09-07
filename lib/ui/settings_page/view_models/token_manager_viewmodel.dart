import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/config_service.dart';

class TokenManagerViewmodel extends ChangeNotifier {
  static const int maxEnabledTokens = maxParallelApiTokens;

  final AccountService _accountService;

  TokenManagerViewmodel({AccountService? accountService})
      : _accountService = accountService ?? AccountService.shared;

  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  List<ApiTokenConfig> get tokens => payloadConfig.settings.apiTokens;
  bool get parallelApiEnabled => payloadConfig.settings.parallelApiEnabled;
  int get enabledTokenCount => tokens.where((entry) => entry.enabled).length;

  /// Balance per token value; null = query failed, absent = not queried yet.
  final Map<String, int?> balances = {};

  /// Latest subscription snapshot per token; null = the last query failed.
  final Map<String, SubscriptionInfo?> subscriptions = {};
  final Set<String> _loadingTokens = {};
  final Map<String, int> _refreshRevisions = {};
  bool _disposed = false;

  bool isBalanceLoading(String token) => _loadingTokens.contains(token);
  bool get isRefreshing => _loadingTokens.isNotEmpty;
  bool hasSubscription(String token) => subscriptions.containsKey(token);
  SubscriptionInfo? subscriptionFor(String token) => subscriptions[token];

  bool addToken(String label, String token) {
    final trimmedToken = token.trim();
    if (trimmedToken.isEmpty) return false;
    if (tokens.any((entry) => entry.token == trimmedToken)) return false;
    final effectiveLabel =
        label.trim().isEmpty ? 'Token ${tokens.length + 1}' : label.trim();
    tokens.add(
      ApiTokenConfig(
        label: effectiveLabel,
        token: trimmedToken,
        enabled: enabledTokenCount < maxEnabledTokens,
      ),
    );
    _persist();
    refreshBalance(trimmedToken);
    return true;
  }

  void removeTokenAt(int index) {
    if (index < 0 || index >= tokens.length) return;
    if (tokens[index].isPrimary) return;
    final removedToken = tokens[index].token;
    tokens.removeAt(index);
    balances.remove(removedToken);
    subscriptions.remove(removedToken);
    _loadingTokens.remove(removedToken);
    _refreshRevisions.remove(removedToken);
    _accountService.invalidate(token: removedToken);
    _persist();
  }

  void setTokenEnabled(int index, bool enabled) {
    if (index < 0 || index >= tokens.length) return;
    if (enabled &&
        !tokens[index].enabled &&
        enabledTokenCount >= maxEnabledTokens) {
      return;
    }
    tokens[index].enabled = enabled;
    _persist();
  }

  void setParallelApiEnabled(bool enabled) {
    payloadConfig.settings.parallelApiEnabled =
        enabled && tokens.any((entry) => entry.enabled);
    _persist();
  }

  void reorderToken(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tokens.length) return;
    if (newIndex < 0 || newIndex >= tokens.length) return;
    final entry = tokens.removeAt(oldIndex);
    tokens.insert(newIndex, entry);
    _persist();
  }

  void renameToken(int index, String label) {
    if (index < 0 || index >= tokens.length) return;
    if (label.trim().isEmpty) return;
    tokens[index].label = label.trim();
    _persist();
  }

  Future<void> refreshBalance(String token) async {
    if (token.isEmpty || _disposed) return;
    final revision = (_refreshRevisions[token] ?? 0) + 1;
    _refreshRevisions[token] = revision;
    _loadingTokens.add(token);
    notifyListeners();
    SubscriptionInfo? info;
    try {
      info = await _accountService.fetchSubscription(
        token: token,
        proxy: payloadConfig.settings.proxy,
        // A user-initiated refresh must bypass AccountService's short cache.
        forceRefresh: true,
      );
    } catch (_) {
      info = null;
    }
    if (_disposed || _refreshRevisions[token] != revision) return;
    _loadingTokens.remove(token);
    balances[token] = info?.anlas;
    subscriptions[token] = info;
    final isPrimary = tokens.any(
      (entry) => entry.isPrimary && entry.token == token,
    );
    if (isPrimary) {
      payloadConfig.settings.subscriptionStatusKnown = info != null;
      if (info != null) {
        payloadConfig.settings.subscriptionTier = info.tier;
        payloadConfig.settings.subscriptionActive = info.active;
      }
    }
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
    payloadConfig.settings.normalizeApiTokens();
    GetIt.I<ConfigService>().saveConfig(payloadConfig.toJson());
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadingTokens.clear();
    _refreshRevisions.clear();
    super.dispose();
  }
}
