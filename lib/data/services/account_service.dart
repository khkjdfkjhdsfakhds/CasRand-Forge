import 'dart:convert';

import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';

/// Subscription snapshot: Anlas balance plus the tier that decides whether
/// generations fall under the Opus free allowance.
class SubscriptionInfo {
  final int? anlas;
  final int tier;
  final bool active;
  final OpusUsage? usage;

  const SubscriptionInfo({
    required this.anlas,
    required this.tier,
    required this.active,
    this.usage,
  });
}

/// Read-only NovelAI account queries (Anlas balance).
class AccountService {
  static final AccountService shared = AccountService(
    apiService: ApiService.shared,
  );

  /// The legacy api.novelai.net host rejects third-party clients; the image
  /// host serves the same subscription payload.
  static const String subscriptionEndpoint =
      'https://image.novelai.net/user/subscription';

  final ApiService _apiService;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final Map<String, ({DateTime fetchedAt, SubscriptionInfo info})> _cache = {};
  final Map<String, Future<SubscriptionInfo?>> _inFlight = {};

  AccountService({
    ApiService? apiService,
    this.cacheTtl = const Duration(minutes: 1),
    this.requestTimeout = const Duration(seconds: 10),
  }) : _apiService = apiService ?? ApiService.shared;

  /// Returns the Anlas balance (fixed + purchased training steps), or null
  /// when the query fails. Never throws.
  Future<int?> fetchAnlasBalance({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    return (await fetchSubscription(
      token: token,
      proxy: proxy,
      forceRefresh: forceRefresh,
    ))
        ?.anlas;
  }

  /// Returns the balance and tier, or null when the query fails.
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    if (token.isEmpty) return null;
    final key = '$proxy\u0000$token';
    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < cacheTtl) {
      return cached.info;
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;

    final future = _fetchSubscription(token: token, proxy: proxy);
    _inFlight[key] = future;
    try {
      final info = await future;
      if (info != null) {
        _cache[key] = (fetchedAt: DateTime.now(), info: info);
      }
      return info;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  Future<SubscriptionInfo?> _fetchSubscription({
    required String token,
    required String proxy,
  }) async {
    try {
      final url = Uri.parse(subscriptionEndpoint);
      final response = await _apiService.get(
        url,
        proxy: proxy,
        headers: {
          'authorization': 'Bearer $token',
          'accept': 'application/json',
        },
      ).timeout(requestTimeout);
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      if (data is! Map<String, dynamic>) return null;

      final tierValue = data['tier'];
      final tier = tierValue is num ? tierValue.toInt() : 0;
      // Be conservative if the field is absent: an old or expired Opus tier
      // must never be treated as an active free allowance.
      final active = data['active'] == true;

      int? anlas;
      final steps = data['trainingStepsLeft'];
      if (steps is Map) {
        final fixed = steps['fixedTrainingStepsLeft'];
        final purchased = steps['purchasedTrainingSteps'];
        anlas = (fixed is num ? fixed.toInt() : 0) +
            (purchased is num ? purchased.toInt() : 0);
      } else if (steps is num) {
        anlas = steps.toInt();
      }

      OpusUsage? usage;
      final usageData = data['usage'];
      if (usageData is Map) {
        final percent = usageData['percent'];
        final secondsPerPercent = usageData['timeUntilNextPercent'];
        if (percent is num && secondsPerPercent is num) {
          usage = OpusUsage(
            percent: percent.toDouble(),
            isNegative: usageData['isNegative'] == true,
            secondsPerPercent: secondsPerPercent.toDouble(),
            observedAt: DateTime.now(),
          );
        }
      }
      return SubscriptionInfo(
        anlas: anlas,
        tier: tier,
        active: active,
        usage: usage,
      );
    } catch (_) {
      return null;
    }
  }

  void invalidate({String? token, String? proxy}) {
    _cache.removeWhere((key, _) {
      final separator = key.indexOf('\u0000');
      final cachedProxy = separator < 0 ? '' : key.substring(0, separator);
      final cachedToken = separator < 0 ? key : key.substring(separator + 1);
      return (token == null || token == cachedToken) &&
          (proxy == null || proxy == cachedProxy);
    });
  }
}
