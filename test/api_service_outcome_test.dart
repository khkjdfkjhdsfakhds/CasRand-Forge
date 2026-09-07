import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';

const _request = ApiRequest(
  endpoint: 'https://example.test/generate',
  proxy: '',
  headers: {'authorization': 'Bearer TOKEN'},
  payload: {'input': 'fixture'},
);

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.body);
  final Stream<List<int>> body;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200);
}

void main() {
  test('timed-out POST exposes its original late response, not a retry',
      () async {
    final response = Completer<http.Response>();
    var posts = 0;
    final api = ApiService(
      requestTimeout: const Duration(milliseconds: 20),
      clientFactory: (_) => MockClient((_) {
        posts++;
        return response.future;
      }),
    );
    addTearDown(api.close);
    final error = await api.fetchData(_request).then<Object>(
          (value) => value,
          onError: (Object error) => error,
        ) as NovelAiApiException;
    // Finish the underlying response even if the regression assertion fails.
    response.complete(http.Response.bytes([10, 20, 30], 200));
    expect(error, isA<NovelAiApiException>());
    expect(error.isTransient, isFalse,
        reason: 'A POST may already be accepted; automatic replay is unsafe.');
    expect(error.isOutcomeUnknown, isTrue);
    final late = await error.lateResponse!;
    expect(late.status, '200');
    expect(late.data, [10, 20, 30]);
    expect(posts, 1);
  });
  for (final sample in <int, String>{
    408: '',
    504: 'Gateway Timeout',
    500: 'upstream timed out after accepting generation',
  }.entries) {
    test('HTTP ${sample.key} timeout is not proof the POST failed', () {
      final response = ApiResponse(
          status: '${sample.key}',
          data: Uint8List.fromList(utf8.encode(sample.value)));
      expect(
          () => ApiService.requireSuccessfulData(response),
          throwsA(
            isA<NovelAiApiException>()
                .having((e) => e.isOutcomeUnknown, 'unknown outcome', isTrue)
                .having((e) => e.isTransient, 'automatic retry', isFalse)
                .having((e) => e.lateResponse, 'no pending response', isNull),
          ));
    });
  }

  test('response-body timeout preserves all eventual bytes', () async {
    final body = StreamController<List<int>>();
    final api = ApiService(
      requestTimeout: const Duration(milliseconds: 20),
      clientFactory: (_) => _StreamingClient(body.stream),
    );
    addTearDown(api.close);
    final outcome = api
        .fetchData(_request)
        .then<Object>((r) => r, onError: (Object e) => e);
    body.add([1, 2]);
    final error = await outcome as NovelAiApiException;
    body.add([3, 4]);
    await body.close();
    expect(error.isOutcomeUnknown, isTrue);
    expect((await error.lateResponse!).data, [1, 2, 3, 4]);
  });

  test('partial response disconnect stays unknown and is not replayable',
      () async {
    final body = StreamController<List<int>>();
    final api = ApiService(clientFactory: (_) => _StreamingClient(body.stream));
    addTearDown(api.close);
    final outcome = api
        .fetchData(_request)
        .then<Object>((r) => r, onError: (Object e) => e);
    body.add([1, 2]);
    body.addError(http.ClientException('fixture incomplete body'));
    await body.close();
    final error = await outcome as NovelAiApiException;
    expect(error.isOutcomeUnknown, isTrue);
    expect(error.isTransient, isFalse);
    expect(error.lateResponse, isNull);
  });

  test('unobserved late disconnect does not become an unhandled async error',
      () async {
    final response = Completer<http.Response>();
    final api = ApiService(
      requestTimeout: const Duration(milliseconds: 20),
      clientFactory: (_) => MockClient((_) => response.future),
    );
    addTearDown(api.close);
    await expectLater(
        api.fetchData(_request), throwsA(isA<NovelAiApiException>()));
    response.completeError(http.ClientException('fixture late disconnect'));
    await Future<void>.delayed(Duration.zero);
    // flutter_test reports any unhandled asynchronous error as a test failure.
  });

  test('new calls use a fresh route while the original late call can finish',
      () async {
    final firstResponse = Completer<http.Response>();
    var connections = 0;
    var posts = 0;
    final api = ApiService(
      requestTimeout: const Duration(milliseconds: 20),
      clientFactory: (_) {
        connections++;
        final first = connections == 1;
        return MockClient((_) {
          posts++;
          return first
              ? firstResponse.future
              : Future.value(http.Response.bytes([9], 200));
        });
      },
    );
    addTearDown(api.close);
    final error = await api.fetchData(_request).then<Object>((r) => r,
        onError: (Object e) => e) as NovelAiApiException;
    final second = await api.fetchData(_request);
    firstResponse.complete(http.Response.bytes([1], 200));
    expect(second.data, [9]);
    expect((await error.lateResponse!).data, [1]);
    expect(posts, 2,
        reason: 'Only the two explicit public calls sent requests.');
    expect(connections, 2);
  });

  test('invalid local payload fails before transport without an unknown POST',
      () async {
    var posts = 0;
    final api = ApiService(
        clientFactory: (_) => MockClient((_) async {
              posts++;
              return http.Response('', 200);
            }));
    addTearDown(api.close);
    await expectLater(
        api.fetchData(ApiRequest(
          endpoint: _request.endpoint,
          proxy: '',
          headers: const {},
          payload: {'invalid': Object()},
        )),
        throwsA(isA<JsonUnsupportedObjectError>()));
    expect(posts, 0);
  });

  test('late INVALID_CACHE_KEYS is surfaced without an implicit new POST',
      () async {
    final response = Completer<http.Response>();
    var posts = 0;
    final api = ApiService(
        requestTimeout: const Duration(milliseconds: 20),
        clientFactory: (_) => MockClient((_) {
              posts++;
              return response.future;
            }));
    addTearDown(api.close);
    final outcome = await api
        .fetchData(const ApiRequest(
          endpoint: 'https://image.novelai.net/ai/generate-image',
          proxy: '',
          headers: {},
          payload: {'input': 'fixture'},
        ))
        .then<Object>((r) => r, onError: (Object e) => e);
    response.complete(http.Response(
        '{"message":"INVALID_CACHE_KEYS","details":{"invalidKeys":["fixture-key"]}}',
        400));
    final error = outcome as NovelAiApiException;
    expect((await error.lateResponse!).status, '400');
    expect(posts, 1);
  });

  test('stopping during preparation prevents the first physical POST',
      () async {
    var posts = 0;
    var shouldSend = true;
    final api = ApiService(
        clientFactory: (_) => MockClient((_) async {
              posts++;
              return http.Response('', 200);
            }));
    addTearDown(api.close);
    final result = api.fetchData(ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {},
      payload: {
        'parameters': {'image': base64Encode(List.filled(4096, 1))}
      },
      shouldSend: () => shouldSend,
    ));
    shouldSend = false;
    await expectLater(result, throwsA(isA<RequestNotSentException>()));
    expect(posts, 0);
  });

  test('stopping after cache rejection prevents its physical re-upload',
      () async {
    var posts = 0;
    var shouldSend = true;
    final api = ApiService(
        clientFactory: (_) => MockClient((_) async {
              posts++;
              shouldSend = false;
              return http.Response(
                  '{"message":"INVALID_CACHE_KEYS","details":{"invalidKeys":["fixture"]}}',
                  400);
            }));
    addTearDown(api.close);
    final result = api.fetchData(ApiRequest(
      endpoint: 'https://image.novelai.net/ai/generate-image',
      proxy: '',
      headers: const {},
      payload: const {'input': 'fixture'},
      shouldSend: () => shouldSend,
    ));
    await expectLater(result, throwsA(isA<RequestNotSentException>()));
    expect(posts, 1);
  });
}
