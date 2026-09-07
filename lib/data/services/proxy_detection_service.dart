import 'dart:async';
import 'dart:io';

typedef ProxyPortProbe = Future<bool> Function(
  String host,
  int port,
  Duration timeout,
);

/// Detects common loopback HTTP proxy listeners used by desktop proxy apps.
///
/// This intentionally mirrors Tiled Upscale's lightweight detection: all
/// candidate ports are probed concurrently and the first successful port in
/// the configured priority order wins. A listening port does not prove that
/// the selected upstream node is fast or stable.
class ProxyDetectionService {
  static const List<int> defaultPorts = [
    7890,
    7897,
    7891,
    1080,
    10808,
    10809,
    20171,
    8080,
  ];

  static const Duration defaultTimeout = Duration(milliseconds: 800);

  final List<int> ports;
  final Duration timeout;
  final ProxyPortProbe _probe;

  ProxyDetectionService({
    this.ports = defaultPorts,
    this.timeout = defaultTimeout,
    ProxyPortProbe? probe,
  }) : _probe = probe ?? _tcpProbe;

  Future<String?> detect({String host = '127.0.0.1'}) async {
    final results = await Future.wait(
      ports.map((port) async => (
            port: port,
            open: await _probe(
              host,
              port,
              timeout,
            )
          )),
    );
    for (final result in results) {
      if (result.open) return '$host:${result.port}';
    }
    return null;
  }

  static Future<bool> _tcpProbe(
    String host,
    int port,
    Duration timeout,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}
