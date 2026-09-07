import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';

class _LocalSocketOverrides extends HttpOverrides {}

void main() {
  for (final sameToken in [true, false]) {
    test(
        'NET-06 ${sameToken ? 'same' : 'different'} token sibling survives another request timeout',
        () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final gotA = Completer<void>();
        final gotB = Completer<void>();
        final handlers = <Future<void>>[];
        final subscription = server.listen((r) {
          final f = () async {
            await r.drain<void>();
            if (r.uri.path == '/a') {
              gotA.complete();
              return;
            }
            gotB.complete();
            await Future<void>.delayed(const Duration(milliseconds: 150));
            try {
              r.response.statusCode = 200;
              r.response.add(utf8.encode('fixture-result'));
              await r.response.close();
            } catch (_) {}
          }();
          handlers.add(f);
        });
        final api =
            ApiService(requestTimeout: const Duration(milliseconds: 250));
        ApiRequest request(String path, String token) => ApiRequest(
            endpoint: 'http://127.0.0.1:${server.port}/$path',
            proxy: '',
            headers: {'authorization': 'Bearer $token'},
            payload: {'fixture': path});
        final a = api
            .fetchData(request('a', 'TOKEN_A'))
            .then<Object>((v) => v, onError: (Object e) => e);
        await gotA.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final watch = Stopwatch()..start();
        final b = api
            .fetchData(request('b', sameToken ? 'TOKEN_A' : 'TOKEN_B'))
            .then<Object>((v) => v, onError: (Object e) => e);
        await gotB.future.timeout(const Duration(seconds: 2));
        final resultA = await a;
        final resultB = await b;
        watch.stop();
        // ignore: avoid_print
        print(
            'sameToken=$sameToken A=${resultA.runtimeType} B=${resultB.runtimeType} BElapsedMs=${watch.elapsedMilliseconds}');
        api.close();
        await server.close(force: true);
        await subscription.cancel();
        await Future.wait(handlers);
        expect(resultB, isA<ApiResponse>(),
            reason: 'B should have its own full response deadline');
      }, _LocalSocketOverrides());
    });
  }
}
