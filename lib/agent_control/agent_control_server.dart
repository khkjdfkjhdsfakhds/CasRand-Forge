import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:nai_casrand/agent_control/agent_control_service.dart';

/// MCP protocol revisions this server understands, newest first.
const supportedMcpProtocolVersions = <String>[
  '2025-11-25',
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

const _mcpInstructions = '''
CasRand Forge is a NovelAI image generator built around cascading random
prompts. Typical flow: get_status → get_prompt_tree / get_config → edit with
set_prompt_node or update_config → start_generation (wait=true) →
get_result_image. Edits are refused while a run is active; stop it first.
Every generation spends the user's NovelAI Anlas, so generate only what the
user asked for. Credentials are never exposed.''';

/// Local-only HTTP endpoint exposing [AgentControlService] as an MCP server
/// (Streamable HTTP, JSON responses) at `/mcp` and as REST at `/api/v1`.
class AgentControlServer {
  AgentControlServer({
    required this.service,
    required this.token,
    required this.serverVersion,
  });

  final AgentControlService service;
  final String token;
  final String serverVersion;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// Binds to the IPv4 loopback interface only. When [preferredPort] is
  /// taken, an ephemeral port is used instead.
  Future<int> start({int preferredPort = 0}) async {
    if (_server != null) return _server!.port;
    HttpServer server;
    try {
      server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, preferredPort);
    } on SocketException {
      if (preferredPort == 0) rethrow;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    server.autoCompress = false;
    _server = server;
    _subscription = server.listen(_handle);
    return server.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await _subscription?.cancel();
    _subscription = null;
    await server?.close(force: true);
  }

  // ---------------------------------------------------------------------------

  bool _isLocalOrigin(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri == null) return false;
    return const {'localhost', '127.0.0.1', '[::1]', '::1'}.contains(uri.host);
  }

  bool _isLocalHostHeader(HttpRequest request) {
    final host = request.headers.host;
    if (host == null) return true;
    return const {'localhost', '127.0.0.1'}.contains(host);
  }

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Bearer ')) return false;
    final presented = header.substring('Bearer '.length).trim();
    // Compare digests so the comparison time does not depend on the token.
    return sha256.convert(utf8.encode(presented)) ==
        sha256.convert(utf8.encode(token));
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      // DNS-rebinding and browser cross-origin protection.
      final origin = request.headers.value('origin');
      if (!_isLocalHostHeader(request) ||
          (origin != null && !_isLocalOrigin(origin))) {
        await _sendJson(response, 403, {'error': 'forbidden_origin'});
        return;
      }
      final path = request.uri.path;
      if (path == '/health' && request.method == 'GET') {
        await _sendJson(response, 200, {
          'ok': true,
          'app': 'CasRand Forge',
          'version': serverVersion,
        });
        return;
      }
      if (!_authorized(request)) {
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        await _sendJson(response, 401, {
          'error': 'unauthorized',
          'message': 'Send "Authorization: Bearer <token>" from '
              'agent-control.json.',
        });
        return;
      }
      if (path == '/mcp') {
        await _handleMcp(request);
      } else if (path.startsWith('/api/v1/')) {
        await _handleRest(request, path.substring('/api/v1/'.length));
      } else {
        await _sendJson(response, 404, {'error': 'not_found'});
      }
    } catch (error, stackTrace) {
      debugPrint('Agent control request failed: $error\n$stackTrace');
      try {
        await _sendJson(response, 500, {
          'error': 'internal_error',
          'message': error.toString(),
        });
      } catch (_) {
        // The client already went away.
      }
    }
  }

  Future<Object?> _readJsonBody(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    if (body.trim().isEmpty) return null;
    return json.decode(body);
  }

  Future<void> _sendJson(HttpResponse response, int status, Object? body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(json.encode(body));
    return response.close();
  }

  // ---------------------------------------------------------------------------
  // REST

  Future<void> _handleRest(HttpRequest request, String route) async {
    final response = request.response;
    final segments = route.split('/').where((s) => s.isNotEmpty).toList();
    try {
      if (request.method == 'GET' && route == 'tools') {
        await _sendJson(response, 200, {
          'tools': service.tools.map((tool) => tool.toJson()).toList(),
        });
        return;
      }
      if (request.method == 'GET' && route == 'status') {
        final result = await service.call('get_status', const {});
        await _sendJson(response, 200, result.data);
        return;
      }
      if (request.method == 'GET' &&
          segments.length == 3 &&
          segments[0] == 'results' &&
          segments[2] == 'image') {
        final id = int.tryParse(segments[1]);
        if (id == null) {
          await _sendJson(response, 400, {'error': 'invalid_argument'});
          return;
        }
        final full = request.uri.queryParameters['size'] != 'preview';
        final image = await service.resultImageBytes(id, full: full);
        response
          ..statusCode = 200
          ..headers.contentType = ContentType.parse(image.mimeType)
          ..add(image.bytes);
        await response.close();
        return;
      }
      if (request.method == 'POST' &&
          segments.length == 2 &&
          segments[0] == 'tools') {
        final body = await _readJsonBody(request);
        final arguments = body == null
            ? <String, dynamic>{}
            : body is Map
                ? body.map((key, value) => MapEntry(key.toString(), value))
                : throw const AgentControlException(
                    'invalid_argument',
                    'The request body must be a JSON object.',
                  );
        final result = await service.call(segments[1], arguments);
        await _sendJson(response, 200, {
          'result': result.data,
          if (result.images.isNotEmpty)
            'images': [
              for (final image in result.images)
                {
                  'mimeType': image.mimeType,
                  'data': base64Encode(image.bytes),
                },
            ],
        });
        return;
      }
      await _sendJson(response, 404, {'error': 'not_found'});
    } on AgentControlException catch (error) {
      await _sendJson(response, error.status, {
        'error': error.code,
        'message': error.message,
      });
    } on FormatException catch (error) {
      await _sendJson(response, 400, {
        'error': 'invalid_json',
        'message': error.message,
      });
    }
  }

  // ---------------------------------------------------------------------------
  // MCP (Streamable HTTP transport, JSON responses, stateless)

  Future<void> _handleMcp(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'POST') {
      // No server-initiated stream is offered; sessions are not used.
      response.headers.set(HttpHeaders.allowHeader, 'POST');
      await _sendJson(response, 405, {'error': 'method_not_allowed'});
      return;
    }
    Object? message;
    try {
      message = await _readJsonBody(request);
    } on FormatException catch (error) {
      await _sendJson(response, 400, _rpcError(null, -32700, error.message));
      return;
    }
    if (message is List) {
      final replies = <Map<String, dynamic>>[];
      for (final item in message) {
        final reply = await _dispatchRpc(item);
        if (reply != null) replies.add(reply);
      }
      if (replies.isEmpty) {
        response.statusCode = HttpStatus.accepted;
        await response.close();
      } else {
        await _sendJson(response, 200, replies);
      }
      return;
    }
    final reply = await _dispatchRpc(message);
    if (reply == null) {
      response.statusCode = HttpStatus.accepted;
      await response.close();
      return;
    }
    await _sendJson(response, 200, reply);
  }

  Map<String, dynamic> _rpcError(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  Map<String, dynamic> _rpcResult(Object? id, Object? result) => {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };

  /// Returns null for notifications and client responses.
  Future<Map<String, dynamic>?> _dispatchRpc(Object? message) async {
    if (message is! Map) {
      return _rpcError(null, -32600, 'Invalid JSON-RPC message.');
    }
    final method = message['method'];
    final hasId = message.containsKey('id');
    final id = message['id'];
    if (method is! String) {
      // A response to a server request (none are sent) or garbage.
      return hasId &&
              !message.containsKey('result') &&
              !message.containsKey('error')
          ? _rpcError(id, -32600, 'Missing method.')
          : null;
    }
    if (!hasId) return null; // notifications/initialized and friends.
    final params = message['params'];
    final paramMap = params is Map
        ? params.map((key, value) => MapEntry(key.toString(), value))
        : <String, dynamic>{};
    switch (method) {
      case 'initialize':
        final requested = paramMap['protocolVersion'];
        final version = supportedMcpProtocolVersions.contains(requested)
            ? requested as String
            : supportedMcpProtocolVersions.first;
        return _rpcResult(id, {
          'protocolVersion': version,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {
            'name': 'casrand-forge',
            'title': 'CasRand Forge',
            'version': serverVersion,
          },
          'instructions': _mcpInstructions,
        });
      case 'ping':
        return _rpcResult(id, {});
      case 'tools/list':
        return _rpcResult(id, {
          'tools': service.tools.map((tool) => tool.toJson()).toList(),
        });
      case 'tools/call':
        final name = paramMap['name'];
        if (name is! String) {
          return _rpcError(id, -32602, 'tools/call needs a tool name.');
        }
        final arguments = paramMap['arguments'];
        final argumentMap = arguments is Map
            ? arguments.map((key, value) => MapEntry(key.toString(), value))
            : <String, dynamic>{};
        try {
          final result = await service.call(name, argumentMap);
          final data = result.data;
          return _rpcResult(id, {
            'content': [
              {
                'type': 'text',
                'text': const JsonEncoder.withIndent(' ').convert(data),
              },
              for (final image in result.images)
                {
                  'type': 'image',
                  'data': base64Encode(image.bytes),
                  'mimeType': image.mimeType,
                },
            ],
            if (data is Map) 'structuredContent': data,
            'isError': false,
          });
        } on AgentControlException catch (error) {
          if (error.code == 'unknown_tool') {
            return _rpcError(id, -32602, error.message);
          }
          return _rpcResult(id, {
            'content': [
              {'type': 'text', 'text': '${error.code}: ${error.message}'},
            ],
            'isError': true,
          });
        }
      case 'resources/list':
        return _rpcResult(id, {'resources': []});
      case 'prompts/list':
        return _rpcResult(id, {'prompts': []});
      default:
        return _rpcError(id, -32601, 'Method not found: $method');
    }
  }
}
