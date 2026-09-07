import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/services/api_service.dart';

class _LocalConnectProxy {
  _LocalConnectProxy._(this._server);

  final HttpServer _server;

  int get port => _server.port;

  static Future<_LocalConnectProxy> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _LocalConnectProxy._(server);
    server.listen(proxy._handleRequest);
    return proxy;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'CONNECT') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    var authority = request.uri.authority.isNotEmpty
        ? request.uri.authority
        : request.uri.toString();
    if (!authority.contains(':')) {
      authority = request.headers.value(HttpHeaders.hostHeader) ?? authority;
    }
    final separator = authority.lastIndexOf(':');
    final host = authority.substring(0, separator);
    final port = int.parse(authority.substring(separator + 1));
    final upstream = await Socket.connect(host, port);
    final downstream = await request.response.detachSocket(
      writeHeaders: false,
    );
    downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    await downstream.flush();
    downstream.listen(
      upstream.add,
      onError: (_) => upstream.destroy(),
      onDone: upstream.destroy,
      cancelOnError: true,
    );
    upstream.listen(
      downstream.add,
      onError: (_) => downstream.destroy(),
      onDone: downstream.destroy,
      cancelOnError: true,
    );
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  late HttpServer httpsServer;
  late _LocalConnectProxy proxy;
  late Uri endpoint;
  late List<int> certificateBytes;

  setUp(() async {
    final certificate = File('test/fixtures/tls/localhost-cert.pem');
    final certificateAuthority = File('test/fixtures/tls/localhost-ca.pem');
    final privateKey = File('test/fixtures/tls/localhost-key.pem');
    certificateBytes = await certificateAuthority.readAsBytes();
    final serverContext = SecurityContext()
      ..useCertificateChain(certificate.path)
      ..usePrivateKey(privateKey.path);
    httpsServer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    httpsServer.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.ok
        ..write('fixture-ok');
      await request.response.close();
    });
    proxy = await _LocalConnectProxy.start();
    endpoint = Uri.parse('https://localhost:${httpsServer.port}/generate');
  });

  tearDown(() async {
    await proxy.close();
    await httpsServer.close(force: true);
  });

  ApiRequest request({required String proxyRoute}) => ApiRequest(
        endpoint: endpoint.toString(),
        proxy: proxyRoute,
        headers: const {'authorization': 'Bearer TEST_TOKEN'},
        payload: const {'input': 'local fixture'},
      );

  test('trusted HTTPS succeeds directly and through a CONNECT proxy', () async {
    HttpClient trustedClient() {
      final context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificatesBytes(certificateBytes);
      return HttpClient(context: context);
    }

    final service = ApiService(ioHttpClientFactory: trustedClient);

    final direct = await service.fetchData(request(proxyRoute: ''));
    final proxied = await service.fetchData(
      request(proxyRoute: '127.0.0.1:${proxy.port}'),
    );

    expect(direct.status, '200');
    expect(proxied.status, '200');
    service.close();
  });

  test('an untrusted certificate is rejected directly and through a proxy',
      () async {
    final service = ApiService();

    await expectLater(
      service.fetchData(request(proxyRoute: '')),
      throwsA(anything),
    );
    await expectLater(
      service.fetchData(request(proxyRoute: '127.0.0.1:${proxy.port}')),
      throwsA(anything),
    );
    service.close();
  });
}
