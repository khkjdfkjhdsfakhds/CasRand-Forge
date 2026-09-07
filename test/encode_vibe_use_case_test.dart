import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  test('derives encode-vibe from a custom generation endpoint', () {
    expect(
      EncodeVibeUseCase.endpointForDebugGenerationPath(
        'http://127.0.0.1:5000/ai/generate-image',
      ),
      'http://127.0.0.1:5000/ai/encode-vibe',
    );
  });
}
