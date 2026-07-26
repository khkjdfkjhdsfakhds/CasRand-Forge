import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:nai_casrand/data/services/api_service.dart';

/// Read-only NovelAI account queries (Anlas balance).
class AccountService {
  /// The legacy api.novelai.net host rejects third-party clients; the image
  /// host serves the same subscription payload.
  static const String subscriptionEndpoint =
      'https://image.novelai.net/user/subscription';

  /// Returns the Anlas balance (fixed + purchased training steps), or null
  /// when the query fails. Never throws.
  Future<int?> fetchAnlasBalance({
    required String token,
    required String proxy,
  }) async {
    if (token.isEmpty) return null;
    try {
      final url = Uri.parse(subscriptionEndpoint);
      final headers = {
        'authorization': 'Bearer $token',
        'accept': 'application/json',
      };
      final client = ApiService().createHttpClient(proxy);
      final response = await (client == null
              ? http.get(url, headers: headers)
              : client.get(url, headers: headers))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body);
      if (data is! Map<String, dynamic>) return null;
      final steps = data['trainingStepsLeft'];
      if (steps is Map) {
        final fixed = steps['fixedTrainingStepsLeft'];
        final purchased = steps['purchasedTrainingSteps'];
        return (fixed is num ? fixed.toInt() : 0) +
            (purchased is num ? purchased.toInt() : 0);
      }
      if (steps is num) return steps.toInt();
      return null;
    } catch (_) {
      return null;
    }
  }
}
