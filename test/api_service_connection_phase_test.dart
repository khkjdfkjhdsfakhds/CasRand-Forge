import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/generation_http_client.dart';

ApiRequest _request(int port, {String proxy = ''}) => ApiRequest(
      endpoint: 'http://127.0.0.1:$port/generate',
      proxy: proxy,
      headers: const {},
      payload: const {'input': 'synthetic'},
    );

void main() {
  test('Stop during connection setup prevents the POST', () async {
    var allowed = true;
    var posts = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      posts++;
      request.response.close();
    });
    final api = ApiService(ioHttpClientFactory: () {
      final client = HttpClient();
      client.connectionFactory = (uri, proxyHost, proxyPort) async {
        final task = await Socket.startConnect(uri.host, uri.port);
        return ConnectionTask.fromSocket(task.socket.then((socket) {
          allowed = false;
          return socket;
        }), task.cancel);
      };
      return client;
    });
    addTearDown(() async {
      api.close();
      await server.close(force: true);
    });
    await expectLater(
        api.fetchData(ApiRequest(
          endpoint: 'http://127.0.0.1:${server.port}/generate',
          proxy: '',
          headers: const {},
          payload: const {},
          shouldSend: () => allowed,
        )),
        throwsA(isA<RequestNotSentException>()));
    expect(posts, 0);
  });

  test('redirect connection failure is after the original POST was sent',
      () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = closed.port;
    await closed.close();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var posts = 0;
    server.listen((request) async {
      await request.drain<void>();
      posts++;
      request.response.statusCode = 303;
      request.response.headers
          .set('location', 'http://127.0.0.1:$closedPort/result');
      await request.response.close();
    });
    final api = ApiService();
    addTearDown(() async {
      api.close();
      await server.close(force: true);
    });
    await expectLater(
        api.fetchData(_request(server.port)),
        throwsA(isA<NovelAiApiException>()
            .having(
                (e) => e.isOutcomeUnknown, 'manual suspension disabled', false)
            .having((e) => e.isTransient, 'scheduler may retry', true)));
    expect(posts, 1);
  });

  test('short idle retirement avoids reuse of a silently stale connection',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      var requests = 0;
      var bytes = '';
      socket.listen((data) {
        bytes += utf8.decode(data);
        if (!bytes.contains('{"input":"synthetic"}')) return;
        bytes = '';
        requests++;
        if (requests == 1) {
          socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok');
        } else {
          socket.destroy();
        }
      });
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    for (final shortIdle in [false, true]) {
      final api = ApiService(
          clientFactory: (_) => GenerationHttpClient(HttpClient()
            ..idleTimeout = Duration(milliseconds: shortIdle ? 10 : 2000)));
      try {
        expect((await api.fetchData(_request(server.port))).status, '200');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (shortIdle) {
          expect((await api.fetchData(_request(server.port))).status, '200');
        } else {
          await expectLater(
              api.fetchData(_request(server.port)),
              throwsA(isA<NovelAiApiException>().having(
                  (e) => e.isOutcomeUnknown, 'stale connection', false)));
        }
      } finally {
        api.close();
      }
    }
  });

  for (final proxy in [false, true]) {
    test(
        'first connection refused ${proxy ? "by proxy" : "directly"} is safely retryable',
        () async {
      final reservation =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reservation.port;
      await reservation.close();
      final api = ApiService();
      addTearDown(api.close);
      await expectLater(
          api.fetchData(_request(proxy ? 1 : port,
              proxy: proxy ? '127.0.0.1:$port' : '')),
          throwsA(isA<NovelAiApiException>()
              .having(
                  (e) => e.isOutcomeUnknown, 'no generation POST sent', false)
              .having((e) => e.isTransient, 'safe automatic retry', true)));
      expect(api.pooledClientCount, 0);
    });
  }

  for (final partialBody in [false, true]) {
    test(
        'complete POST then dropped ${partialBody ? "body" : "headers"} is retryable without immediate replay',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      var posts = 0;
      server.listen((socket) {
        sockets.add(socket);
        final bytes = <int>[];
        var handled = false;
        socket.listen((data) async {
          bytes.addAll(data);
          if (!handled &&
              utf8
                  .decode(bytes, allowMalformed: true)
                  .contains('{"input":"synthetic"}')) {
            handled = true;
            posts++;
            if (partialBody) {
              socket.write('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc');
              await socket.flush();
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            socket.destroy();
          }
        });
      });
      final api = ApiService();
      addTearDown(() async {
        api.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      await expectLater(
          api.fetchData(_request(server.port)),
          throwsA(isA<NovelAiApiException>()
              .having((e) => e.isOutcomeUnknown, 'manual suspension disabled',
                  false)
              .having((e) => e.isTransient, 'scheduler may retry', true)));
      expect(posts, 1);
    });
  }
}
