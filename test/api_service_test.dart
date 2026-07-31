import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/api_service.dart';

void main() {
  test('reuses a successfully uploaded generation image by cache key',
      () async {
    final requestBodies = <Map<String, dynamic>>[];
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    final image = base64Encode(List<int>.filled(4096, 7));
    final request = ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: {
        'input': 'test',
        'parameters': {'image': image, 'strength': 0.5},
      },
    );

    await service.fetchData(request);
    await service.fetchData(request);

    final firstParameters =
        requestBodies[0]['parameters'] as Map<String, dynamic>;
    final secondParameters =
        requestBodies[1]['parameters'] as Map<String, dynamic>;
    expect(firstParameters['image'], image);
    expect(firstParameters['image_cache_secret_key'], isA<String>());
    expect(firstParameters['image_cache_secret_key'], isNotEmpty);
    expect(secondParameters, isNot(contains('image')));
    expect(
      secondParameters['image_cache_secret_key'],
      firstParameters['image_cache_secret_key'],
    );
    expect(jsonEncode(requestBodies[1]).length, lessThan(image.length ~/ 4));
    expect(
      (request.payload['parameters'] as Map<String, dynamic>)['image'],
      image,
    );
    service.close();
  });

  test('caches masks and generation reference images with official fields',
      () async {
    final requestBodies = <Map<String, dynamic>>[];
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return http.Response.bytes([1], 200);
      }),
    );
    final request = ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: {
        'parameters': {
          'image': base64Encode([1, 2, 3]),
          'mask': base64Encode([4, 5, 6]),
          'reference_image': base64Encode([7, 8, 9]),
          'reference_image_multiple': [
            base64Encode([10, 11]),
            base64Encode([12, 13]),
          ],
          'director_reference_images': [
            base64Encode([14, 15])
          ],
        },
      },
    );

    await service.fetchData(request);
    await service.fetchData(request);

    final first = requestBodies[0]['parameters'] as Map<String, dynamic>;
    final second = requestBodies[1]['parameters'] as Map<String, dynamic>;
    expect(first['mask_cache_secret_key'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(
      first['reference_image_cache_secret_key'],
      matches(RegExp(r'^[0-9a-f]{64}$')),
    );
    expect(first, isNot(contains('reference_image_multiple')));
    expect(first, isNot(contains('director_reference_images')));
    expect(
      first['reference_image_multiple_cached'],
      everyElement(allOf(contains('cache_secret_key'), contains('data'))),
    );
    expect(
      first['director_reference_images_cached'],
      everyElement(allOf(contains('cache_secret_key'), contains('data'))),
    );

    expect(second, isNot(contains('image')));
    expect(second, isNot(contains('mask')));
    expect(second, isNot(contains('reference_image')));
    expect(
      second['reference_image_multiple_cached'],
      everyElement(
          allOf(contains('cache_secret_key'), isNot(contains('data')))),
    );
    expect(
      second['director_reference_images_cached'],
      everyElement(
          allOf(contains('cache_secret_key'), isNot(contains('data')))),
    );
    service.close();
  });

  test('restores an invalid cached image and retries exactly once', () async {
    final requestBodies = <Map<String, dynamic>>[];
    var requestCount = 0;
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requestBodies.add(body);
        final parameters = body['parameters'] as Map<String, dynamic>;
        if (requestCount == 2) {
          return http.Response(
            jsonEncode({
              'message': 'INVALID_CACHE_KEYS',
              'details': {
                'invalidKeys': [parameters['image_cache_secret_key']],
              },
            }),
            400,
          );
        }
        return http.Response.bytes([1], 200);
      }),
    );
    final image = base64Encode([1, 2, 3, 4]);
    final request = ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: {
        'parameters': {'image': image},
      },
    );

    await service.fetchData(request);
    final response = await service.fetchData(request);

    expect(response.status, '200');
    expect(requestBodies, hasLength(3));
    final cached = requestBodies[1]['parameters'] as Map<String, dynamic>;
    final retried = requestBodies[2]['parameters'] as Map<String, dynamic>;
    expect(cached, isNot(contains('image')));
    expect(retried['image'], image);
    expect(
      retried['image_cache_secret_key'],
      cached['image_cache_secret_key'],
    );
    service.close();
  });

  test('does not retry an invalid cache response more than once', () async {
    var requestCount = 0;
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final parameters = body['parameters'] as Map<String, dynamic>;
        if (requestCount == 1) return http.Response.bytes([1], 200);
        return http.Response(
          jsonEncode({
            'message': 'INVALID_CACHE_KEYS',
            'details': {
              'invalidKeys': [parameters['image_cache_secret_key']],
            },
          }),
          400,
        );
      }),
    );
    final request = ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: {
        'parameters': {
          'image': base64Encode([1, 2, 3])
        },
      },
    );

    await service.fetchData(request);
    final response = await service.fetchData(request);

    expect(response.status, '400');
    expect(requestCount, 3);
    service.close();
  });

  test('restores only the invalid mask while keeping the cached image omitted',
      () async {
    final requestBodies = <Map<String, dynamic>>[];
    var requestCount = 0;
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requestBodies.add(body);
        final parameters = body['parameters'] as Map<String, dynamic>;
        if (requestCount == 2) {
          return http.Response(
            jsonEncode({
              'message': 'INVALID_CACHE_KEYS',
              'details': {
                'invalidKeys': [parameters['mask_cache_secret_key']],
              },
            }),
            400,
          );
        }
        return http.Response.bytes([1], 200);
      }),
    );
    final image = base64Encode([1, 2, 3]);
    final mask = base64Encode([4, 5, 6]);
    final request = ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: {
        'parameters': {'image': image, 'mask': mask},
      },
    );

    await service.fetchData(request);
    await service.fetchData(request);

    final retried = requestBodies[2]['parameters'] as Map<String, dynamic>;
    expect(retried, isNot(contains('image')));
    expect(retried['mask'], mask);
    service.close();
  });

  test('isolates image cache sessions by authorization credential', () async {
    final requestBodies = <Map<String, dynamic>>[];
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return http.Response.bytes([1], 200);
      }),
    );
    final image = base64Encode([1, 2, 3]);
    ApiRequest requestFor(String authorization) => ApiRequest(
          endpoint: 'https://image.novelai.net/ai/generate-image',
          proxy: '',
          headers: {'authorization': authorization},
          payload: {
            'parameters': {'image': image},
          },
        );

    await service.fetchData(requestFor('Bearer account-a'));
    await service.fetchData(requestFor('Bearer account-b'));

    final first = requestBodies[0]['parameters'] as Map<String, dynamic>;
    final second = requestBodies[1]['parameters'] as Map<String, dynamic>;
    expect(first['image'], image);
    expect(second['image'], image);
    expect(
      second['image_cache_secret_key'],
      isNot(first['image_cache_secret_key']),
    );
    service.close();
  });

  test('uploads different image bytes with different cache keys', () async {
    final requestBodies = <Map<String, dynamic>>[];
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return http.Response.bytes([1], 200);
      }),
    );
    final firstImage = base64Encode([1, 2, 3]);
    final secondImage = base64Encode([1, 2, 4]);
    ApiRequest requestFor(String image) => ApiRequest(
          endpoint: 'https://image.novelai.net/ai/generate-image',
          proxy: '',
          headers: const {'authorization': 'Bearer account-a'},
          payload: {
            'parameters': {'image': image},
          },
        );

    await service.fetchData(requestFor(firstImage));
    await service.fetchData(requestFor(secondImage));

    final first = requestBodies[0]['parameters'] as Map<String, dynamic>;
    final second = requestBodies[1]['parameters'] as Map<String, dynamic>;
    expect(first['image'], firstImage);
    expect(second['image'], secondImage);
    expect(
      second['image_cache_secret_key'],
      isNot(first['image_cache_secret_key']),
    );
    service.close();
  });

  test('leaves non-generation image endpoints unchanged', () async {
    final requestBodies = <Map<String, dynamic>>[];
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return http.Response.bytes([1], 200);
      }),
    );
    final payload = {
      'image': base64Encode([1, 2, 3]),
      'parameters': {
        'image': base64Encode([4, 5, 6])
      },
    };

    for (final path in ['augment-image', 'encode-vibe']) {
      await service.fetchData(ApiRequest(
        endpoint: 'https://image.novelai.net/ai/$path',
        proxy: '',
        headers: const {'authorization': 'Bearer account-a'},
        payload: payload,
      ));
    }

    expect(requestBodies, [payload, payload]);
    service.close();
  });

  test('leaves custom generate-image endpoints unchanged', () async {
    final requestBodies = <Map<String, dynamic>>[];
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestBodies.add(
          jsonDecode(request.body) as Map<String, dynamic>,
        );
        return http.Response.bytes([1], 200);
      }),
    );
    final image = base64Encode([1, 2, 3]);
    final payload = {
      'parameters': {'image': image},
    };
    final request = ApiRequest(
      endpoint: 'https://custom.example/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: payload,
    );

    await service.fetchData(request);
    await service.fetchData(request);

    expect(requestBodies, [payload, payload]);
    service.close();
  });

  test('generation cache hashing yields to the calling isolate', () async {
    final eventLoopTurnCompleted = Completer<void>();
    var eventLoopWasResponsive = false;
    final service = ApiService(
      clientFactory: (_) => MockClient((_) async {
        eventLoopWasResponsive = eventLoopTurnCompleted.isCompleted;
        return http.Response.bytes([1], 200);
      }),
    );
    final image = base64Encode(List<int>.filled(8 * 1024 * 1024, 7));
    final request = ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: {
        'parameters': {'image': image},
      },
    );
    Timer.run(eventLoopTurnCompleted.complete);

    await service.fetchData(request);

    expect(eventLoopWasResponsive, isTrue);
    service.close();
  });

  test('concurrent requests never use a key before an image upload succeeds',
      () async {
    final firstRequestArrived = Completer<void>();
    final releaseFirstRequest = Completer<void>();
    final requestBodies = <Map<String, dynamic>>[];
    var requestCount = 0;
    var imageUploadSucceeded = false;
    final service = ApiService(
      clientFactory: (_) => MockClient((request) async {
        requestCount++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requestBodies.add(body);
        final parameters = body['parameters'] as Map<String, dynamic>;
        if (!parameters.containsKey('image')) {
          expect(imageUploadSucceeded, isTrue);
        }
        if (requestCount == 1) {
          firstRequestArrived.complete();
          await releaseFirstRequest.future;
        }
        if (parameters.containsKey('image')) imageUploadSucceeded = true;
        return http.Response.bytes([1], 200);
      }),
    );
    final image = base64Encode([1, 2, 3]);
    final request = ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {'authorization': 'Bearer account-a'},
      payload: {
        'parameters': {'image': image},
      },
    );

    final first = service.fetchData(request);
    await firstRequestArrived.future;
    final second = service.fetchData(request);
    await Future<void>.delayed(Duration.zero);
    releaseFirstRequest.complete();
    await Future.wait([first, second]);

    expect(requestBodies, hasLength(2));
    expect(
      requestBodies.any((body) =>
          (body['parameters'] as Map<String, dynamic>).containsKey('image')),
      isTrue,
    );
    for (final body in requestBodies) {
      final parameters = body['parameters'] as Map<String, dynamic>;
      expect(parameters['image_cache_secret_key'], isNotEmpty);
    }
    service.close();
  });

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

  test('isolates persistent HTTP clients by authorization credential',
      () async {
    var createdClients = 0;
    final service = ApiService(
      clientFactory: (_) {
        createdClients++;
        String? boundAuthorization;
        return MockClient((request) async {
          final authorization = request.headers['authorization'];
          boundAuthorization ??= authorization;
          if (authorization != boundAuthorization) {
            throw StateError('connection reused across credentials');
          }
          return http.Response('{}', 200);
        });
      },
    );

    final responses = await Future.wait([
      service.fetchData(const ApiRequest(
        endpoint: 'https://example.test/generate',
        proxy: '127.0.0.1:7897',
        headers: {'authorization': 'Bearer account-a'},
        payload: {},
      )),
      service.fetchData(const ApiRequest(
        endpoint: 'https://example.test/generate',
        proxy: '127.0.0.1:7897',
        headers: {'authorization': 'Bearer account-b'},
        payload: {},
      )),
    ]);

    expect(responses.map((response) => response.status), ['200', '200']);
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
