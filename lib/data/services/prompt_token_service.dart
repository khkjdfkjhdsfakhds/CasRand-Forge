import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:nai_casrand/data/use_cases/prompt_tokenizer.dart';

/// One lazy worker for the session. Only text crosses the isolate boundary;
/// anonymous definition downloads never contain a prompt or account token.
class PromptTokenService {
  static final instance = PromptTokenService();
  final Future<String> Function() cacheDirectory;
  PromptTokenService({Future<String> Function()? cacheDirectory})
      : cacheDirectory = cacheDirectory ?? _defaultCache;
  static Future<String> _defaultCache() async =>
      '${(await getApplicationSupportDirectory()).path}/prompt-tokenizers-v2';
  Future<SendPort>? _starting;
  Isolate? _worker;
  ReceivePort? _responses;
  ReceivePort? _lifecycle;
  var _nextId = 0;
  final _pending = <int, Completer<List<int>>>{};

  Future<List<int>> count(String model, List<String> texts) async {
    final port = await (_starting ??= _start());
    final id = ++_nextId;
    final completer = Completer<List<int>>();
    _pending[id] = completer;
    port.send([id, promptTokenizerFor(model).index, texts]);
    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } finally {
      _pending.remove(id);
    }
  }

  Future<SendPort> _start() async {
    try {
      final directory = await cacheDirectory();
      final ready = Completer<SendPort>();
      final responses = _responses = ReceivePort();
      final lifecycle = _lifecycle = ReceivePort();
      lifecycle.listen((_) {
        if (!identical(_responses, responses)) return;
        if (!ready.isCompleted) {
          ready.completeError(StateError('Tokenizer stopped'));
        }
        dispose();
      });
      responses.listen((message) {
        if (message is SendPort) {
          ready.complete(message);
        } else if (message is List) {
          final pending = _pending[message[0]];
          if (pending == null || pending.isCompleted) return;
          if (message[1] is List) {
            pending.complete((message[1] as List).cast<int>());
          } else {
            pending.completeError(StateError('Tokenizer unavailable'));
          }
        }
      });
      _worker = await Isolate.spawn(
          _tokenWorker, [responses.sendPort, directory],
          onExit: lifecycle.sendPort,
          onError: lifecycle.sendPort,
          errorsAreFatal: true);
      return await ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      _starting = null;
      _responses?.close();
      _lifecycle?.close();
      rethrow;
    }
  }

  void dispose() {
    _worker?.kill(priority: Isolate.immediate);
    _responses?.close();
    _responses = null;
    _lifecycle?.close();
    _starting = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('Disposed'));
    }
    _pending.clear();
  }
}

void _tokenWorker(List<dynamic> args) {
  final reply = args[0] as SendPort;
  final directory = args[1] as String;
  final requests = ReceivePort();
  final tokenizers = <PromptTokenizerKind, Future<PromptTokenizer>>{};
  reply.send(requests.sendPort);
  requests.listen((message) async {
    final request = message as List;
    final kind = PromptTokenizerKind.values[request[1] as int];
    try {
      final tokenizer = await tokenizers.putIfAbsent(
          kind, () => _loadTokenizer(kind, directory));
      final texts = (request[2] as List).cast<String>();
      reply.send([
        request[0],
        texts
            .map((text) => PromptTokenDisplay.count(tokenizer, text, kind))
            .toList()
      ]);
    } catch (_) {
      tokenizers.remove(kind); // A user retry may download/load again.
      reply.send([request[0], null]);
    }
  });
}

Future<PromptTokenizer> _loadTokenizer(
    PromptTokenizerKind kind, String directory) async {
  final name = kind == PromptTokenizerKind.qwen ? 'qwen35' : kind.name;
  final file = File('$directory/${name}_tokenizer.def');
  if (await file.exists()) {
    try {
      if (await file.length() <= 8 * 1024 * 1024) {
        return PromptTokenizer.fromDefinition(kind, await file.readAsBytes());
      }
    } catch (_) {
      // An interrupted or obsolete local cache is replaced from the origin.
    }
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(
        'https://novelai.net/tokenizer/compressed/${name}_tokenizer.def?v=2&static=true'));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const HttpException('Definition unavailable');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.add(chunk);
      if (bytes.length > 8 * 1024 * 1024) {
        throw const FormatException('Definition too large');
      }
    }
    final data = bytes.takeBytes();
    final tokenizer = PromptTokenizer.fromDefinition(kind, data);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part');
    await temporary.writeAsBytes(data, flush: true);
    await temporary.rename(file.path);
    return tokenizer;
  } finally {
    client.close(force: true);
  }
}
