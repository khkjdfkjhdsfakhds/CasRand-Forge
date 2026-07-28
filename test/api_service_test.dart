import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/api_service.dart';

void main() {
  test('successful response data passes through unchanged', () {
    final data = Uint8List.fromList([1, 2, 3]);

    expect(
      ApiService.requireSuccessfulData(
        ApiResponse(status: '200', data: data),
      ),
      same(data),
    );
  });

  test('server timeout JSON becomes a readable transient API error', () {
    final data = Uint8List.fromList(utf8.encode(jsonEncode({
      'statusCode': 500,
      'message': 'read tcp 10.5.237.177:3000->10.4.246.151:56276: i/o timeout',
    })));

    expect(
      () => ApiService.requireSuccessfulData(
        ApiResponse(status: '500', data: data),
        operation: 'generate the image',
      ),
      throwsA(
        isA<NovelAiApiException>()
            .having((error) => error.statusCode, 'statusCode', 500)
            .having((error) => error.isTransient, 'isTransient', isTrue)
            .having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('NovelAI server timed out'),
                contains('HTTP 500'),
                contains('i/o timeout'),
                isNot(contains('End of Central Directory')),
              ),
            ),
      ),
    );
  });

  test('reuses one HTTP client per proxy route', () {
    var createdClients = 0;
    final service = ApiService(
      clientFactory: (_) {
        createdClients++;
        return MockClient((_) async => http.Response('', 200));
      },
    );

    final directA = service.clientForProxy('');
    final directB = service.clientForProxy('');
    final proxiedA = service.clientForProxy('127.0.0.1:7890');
    final proxiedB = service.clientForProxy('127.0.0.1:7890');

    expect(identical(directA, directB), isTrue);
    expect(identical(proxiedA, proxiedB), isTrue);
    expect(identical(directA, proxiedA), isFalse);
    expect(createdClients, 2);
    expect(service.pooledClientCount, 2);
    service.close();
  });

  test('subscription cache avoids repeat network calls and force refreshes',
      () async {
    var requests = 0;
    final api = ApiService(
      clientFactory: (_) => MockClient((_) async {
        requests++;
        return http.Response(
          jsonEncode({
            'tier': 1,
            'active': true,
            'trainingStepsLeft': {
              'fixedTrainingStepsLeft': 100,
              'purchasedTrainingSteps': requests,
            },
          }),
          200,
        );
      }),
    );
    final accounts = AccountService(apiService: api);

    final first = await accounts.fetchSubscription(
      token: 'pst-test',
      proxy: '',
    );
    final cached = await accounts.fetchSubscription(
      token: 'pst-test',
      proxy: '',
    );
    final refreshed = await accounts.fetchSubscription(
      token: 'pst-test',
      proxy: '',
      forceRefresh: true,
    );

    expect(first?.anlas, 101);
    expect(cached?.anlas, 101);
    expect(refreshed?.anlas, 102);
    expect(requests, 2);
    api.close();
  });
}
