import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/use_cases/encode_vibe_use_case.dart';

class _RecordingApiService extends ApiService {
  ApiRequest? lastRequest;
  ApiResponse response;

  _RecordingApiService(this.response);

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    lastRequest = request;
    return response;
  }
}

void main() {
  const model = 'nai-diffusion-4-5-full';

  test('stopped Vibe preparation never sends a paid encoding POST', () async {
    var posts = 0;
    final api = ApiService(
        clientFactory: (_) => MockClient((_) async {
              posts++;
              return http.Response('encoding', 200);
            }));
    addTearDown(api.close);
    await expectLater(
        EncodeVibeUseCase(apiService: api)(
          imageBytes: Uint8List.fromList([1, 2, 3]),
          informationExtracted: 0.7,
          model: model,
          token: 'TOKEN',
          proxy: '',
          shouldSend: () => false,
        ),
        throwsA(isA<RequestNotSentException>()));
    expect(posts, 0);
  });

  test('posts the official encode-vibe request and returns Base64 bytes',
      () async {
    final service = _RecordingApiService(
      ApiResponse(status: '200', data: Uint8List.fromList([10, 20, 30])),
    );
    final useCase = EncodeVibeUseCase(apiService: service);

    final result = await useCase(
      imageBytes: Uint8List.fromList([1, 2, 3]),
      informationExtracted: 0.7,
      model: model,
      token: 'test-token',
      proxy: '127.0.0.1:8080',
    );

    expect(result, base64Encode([10, 20, 30]));
    final request = service.lastRequest!;
    expect(request.endpoint, EncodeVibeUseCase.officialEndpoint);
    expect(request.proxy, '127.0.0.1:8080');
    expect(request.headers['authorization'], 'Bearer test-token');
    expect(request.headers['content-type'], 'application/json');
    final correlationId = request.headers['x-correlation-id']!;
    expect(correlationId, hasLength(6));
    expect(correlationId, matches(RegExp(r'^[A-Za-z0-9]{6}$')));
    expect(
      DateTime.tryParse(request.headers['x-initiated-at']!),
      isNotNull,
    );
    expect(request.payload, {
      'image': base64Encode([1, 2, 3]),
      'information_extracted': 0.7,
      'mask': null,
      'model': model,
    });
  });

  test('surfaces server error messages and status codes', () async {
    final service = _RecordingApiService(
      ApiResponse(
        status: '402',
        data: Uint8List.fromList(
          utf8.encode(jsonEncode({'message': 'Not enough Anlas'})),
        ),
      ),
    );
    final useCase = EncodeVibeUseCase(apiService: service);

    await expectLater(
      useCase(
        imageBytes: Uint8List.fromList([1]),
        informationExtracted: 0.7,
        model: model,
        token: 'test-token',
        proxy: '',
      ),
      throwsA(
        isA<VibeEncodingException>()
            .having((error) => error.statusCode, 'statusCode', 402)
            .having(
              (error) => error.message,
              'message',
              contains('Not enough Anlas'),
            ),
      ),
    );
  });

  test('rejects empty successful responses', () async {
    final service = _RecordingApiService(
      ApiResponse(status: '200', data: Uint8List(0)),
    );
    final useCase = EncodeVibeUseCase(apiService: service);

    await expectLater(
      useCase(
        imageBytes: Uint8List.fromList([1]),
        informationExtracted: 0.7,
        model: model,
        token: 'test-token',
        proxy: '',
      ),
      throwsA(
        isA<VibeEncodingException>().having(
          (error) => error.message,
          'message',
          contains('empty Vibe encoding'),
        ),
      ),
    );
  });

  testWidgets('Vibe uses the transport deadline, not an earlier replay window',
      (tester) async {
    final response = Completer<http.Response>();
    var posts = 0;
    final api = ApiService(
        clientFactory: (_) => MockClient((_) {
              posts++;
              return response.future;
            }));
    addTearDown(api.close);
    final useCase = EncodeVibeUseCase(apiService: api);
    Object? outcome;
    final operation = useCase(
      imageBytes: Uint8List.fromList([1, 2, 3]),
      informationExtracted: 0.7,
      model: model,
      token: 'TOKEN',
      proxy: '',
    ).then<void>((value) {
      outcome = value;
    }, onError: (Object error) {
      outcome = error;
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 125));
    final prematureOutcome = outcome;
    response.complete(http.Response.bytes([10, 20, 30], 200));
    await tester.pump();
    await operation;
    expect(prematureOutcome, isNull,
        reason:
            'The original HTTP request is still within its three-minute deadline.');
    expect(outcome, base64Encode([10, 20, 30]));
    expect(posts, 1);
  });

  testWidgets('late Vibe extraction retains its encoding without another POST',
      (tester) async {
    final response = Completer<http.Response>();
    var posts = 0;
    final api = ApiService(
        requestTimeout: const Duration(seconds: 1),
        clientFactory: (_) => MockClient((_) {
              posts++;
              return response.future;
            }));
    addTearDown(api.close);
    Object? outcome;
    final operation = EncodeVibeUseCase(apiService: api)(
      imageBytes: Uint8List.fromList([1]),
      informationExtracted: 0.7,
      model: model,
      token: 'TOKEN',
      proxy: '',
    ).then<void>((result) {
      outcome = result;
    }, onError: (Object error) {
      outcome = error;
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await operation;
    final error = outcome as VibeEncodingException;
    expect(error.isOutcomeUnknown, isTrue);
    expect(error.isTransient, isFalse);
    expect(error.lateResponse, isNull,
        reason: 'Encoded Vibe bytes must never enter the image ZIP pipeline.');
    response.complete(http.Response.bytes([10, 20, 30], 200));
    await tester.pump();
    expect(await error.lateEncoding!, base64Encode([10, 20, 30]));
    expect(posts, 1);
  });

  test('Vibe rate limiting preserves the account cooldown', () async {
    final api = ApiService(
        clientFactory: (_) => MockClient((_) async => http.Response(
            'rate limited', 429,
            headers: {'retry-after': '60'})));
    addTearDown(api.close);
    await expectLater(
        EncodeVibeUseCase(apiService: api)(
          imageBytes: Uint8List.fromList([1]),
          informationExtracted: 0.7,
          model: model,
          token: 'TOKEN',
          proxy: '',
        ),
        throwsA(isA<VibeEncodingException>()
            .having((e) => e.isRateLimited, 'rate limited', isTrue)
            .having(
                (e) => e.retryAfter, 'cooldown', const Duration(seconds: 60))));
  });

  test('derives encode-vibe from a custom generation endpoint', () {
    expect(
      EncodeVibeUseCase.endpointForDebugGenerationPath(
        'http://127.0.0.1:5000/ai/generate-image',
      ),
      'http://127.0.0.1:5000/ai/encode-vibe',
    );
  });
}
