import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';

void main() {
  test('rate-limit response preserves Retry-After for the account scheduler',
      () async {
    final api = ApiService(
        clientFactory: (_) => MockClient((_) async => http.Response(
            '{"message":"rate limited"}', 429,
            headers: {'Retry-After': '60'})));
    addTearDown(api.close);
    final response = await api.fetchData(const ApiRequest(
      endpoint: 'https://example.test/generate',
      proxy: '',
      headers: {},
      payload: {},
    ));
    try {
      ApiService.requireSuccessfulData(response);
      fail('429 should be reported as a typed API error');
    } on NovelAiApiException catch (error) {
      expect(error.retryAfter, const Duration(seconds: 60));
      expect(error.isRateLimited, isTrue);
      expect(error.isOutcomeUnknown, isFalse);
    }
  });
  for (final sample in <String, Duration?>{
    '60': const Duration(seconds: 60),
    '0': Duration.zero,
    '-3': null,
    '1.5': null,
    '+3': null,
    'not-a-date': null,
    '999999999999999999999999999999999999': const Duration(hours: 24),
    '86401': const Duration(hours: 24),
    'Sat, 05 Sep 2026 01:02:00 GMT': const Duration(minutes: 2),
    'Sat, 05 Sep 2026 00:59:00 GMT': Duration.zero,
    'Sun, 06 Sep 2026 02:00:00 GMT': const Duration(hours: 24),
  }.entries) {
    test('Retry-After ${sample.key} is parsed and bounded', () {
      final response = ApiResponse(
        status: '429',
        data: Uint8List.fromList(utf8.encode('{}')),
        headers: {'ReTrY-AfTeR': sample.key},
        receivedAt: DateTime.utc(2026, 9, 5, 1),
      );
      expect(
        () => ApiService.requireSuccessfulData(response),
        throwsA(isA<NovelAiApiException>().having(
          (error) => error.retryAfter,
          'retryAfter',
          sample.value,
        )),
      );
    });
  }

  for (final status in [401, 402, 403, 400, 429, 503]) {
    test('HTTP $status carries its account/retry classification', () {
      final response = ApiResponse(status: '$status', data: Uint8List(0));
      expect(
          () => ApiService.requireSuccessfulData(response),
          throwsA(
            isA<NovelAiApiException>()
                .having((error) => error.isAccountBlocked, 'account blocked',
                    [401, 402, 403].contains(status))
                .having((error) => error.isRateLimited, 'rate limited',
                    status == 429)
                .having((error) => error.isTransient, 'transient',
                    [429, 503].contains(status)),
          ));
    });
  }
}
