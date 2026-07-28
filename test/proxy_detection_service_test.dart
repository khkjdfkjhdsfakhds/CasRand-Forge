import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/services/proxy_detection_service.dart';

void main() {
  test('probes all Tiled Upscale ports and keeps their priority order',
      () async {
    final probed = <int>[];
    final service = ProxyDetectionService(
      probe: (host, port, timeout) async {
        probed.add(port);
        if (port == 7890) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return true;
        }
        if (port == 7897) return true;
        return false;
      },
    );

    final result = await service.detect();

    expect(result, '127.0.0.1:7890');
    expect(probed, unorderedEquals(ProxyDetectionService.defaultPorts));
  });

  test('returns null when no common local proxy port is listening', () async {
    final service = ProxyDetectionService(
      ports: const [7890, 7897],
      probe: (host, port, timeout) async => false,
    );

    expect(await service.detect(), isNull);
  });

  test('detects a real loopback TCP listener', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final service = ProxyDetectionService(ports: [server.port]);

    expect(await service.detect(), '127.0.0.1:${server.port}');
  });
}
