import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/agent_control/agent_control_controller.dart';
import 'package:nai_casrand/agent_control/agent_control_server.dart';
import 'package:nai_casrand/agent_control/agent_control_service.dart';
import 'package:nai_casrand/agent_control/agent_generation_port.dart';
import 'package:nai_casrand/agent_control/json_edit.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/agent_control/agent_control_settings_tiles.dart';

class _FakeGenerationPort implements AgentGenerationPort {
  bool active = false;
  bool stopping = false;
  bool busy = false;
  bool refuseStart = false;
  int completed = 0;
  int startCalls = 0;
  final List<AgentResultView> views = [];
  void Function()? onStart;

  @override
  bool get isActive => active;

  @override
  bool get isStopping => stopping;

  @override
  bool get isBusy => busy;

  @override
  int get completedCount => completed;

  @override
  List<AgentResultView> get results => List.unmodifiable(views);

  @override
  void start() {
    startCalls++;
    if (refuseStart) return;
    active = true;
    onStart?.call();
  }

  @override
  void stop() => active = false;

  void finishWith(AgentResultView view) {
    views.add(view);
    completed++;
    active = false;
  }
}

Uint8List _png(int width, int height) => Uint8List.fromList(
      img.encodePng(img.Image(width: width, height: height)),
    );

AgentResultView _result(Object identity, {Uint8List? bytes}) => AgentResultView(
      identity: identity,
      status: bytes == null ? 'failed' : 'succeeded',
      title: 'result.png',
      info: 'prompt comment',
      details: const {'input': '1girl', 'seed': 42},
      imageBytes: bytes,
      currentFilePath: bytes == null ? null : '/tmp/result.png',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('json_edit', () {
    test('pointer get, set, append and remove', () {
      final doc = deepCopyJson({
        'a': {
          'list': [1, 2, 3],
          'x/y': true,
        },
      });
      expect(getAtJsonPointer(doc, '/a/list/1'), 2);
      expect(getAtJsonPointer(doc, 'a/x~1y'), true);
      setAtJsonPointer(doc, '/a/list/-', 4);
      setAtJsonPointer(doc, '/a/list/0', 9);
      setAtJsonPointer(doc, '/a/new', 'v');
      removeAtJsonPointer(doc, '/a/list/1');
      expect(doc['a']['list'], [9, 3, 4]);
      expect(doc['a']['new'], 'v');
      expect(() => getAtJsonPointer(doc, '/a/missing'),
          throwsA(isA<JsonEditException>()));
      expect(() => setAtJsonPointer(doc, '/a/list/9', 1),
          throwsA(isA<JsonEditException>()));
    });

    test('merge patch follows RFC 7386', () {
      final merged = applyJsonMergePatch(
        {
          'a': 'b',
          'c': {'d': 'e', 'f': 'g'},
        },
        {
          'a': 'z',
          'c': {'f': null},
        },
      );
      expect(merged, {
        'a': 'z',
        'c': {'d': 'e'},
      });
    });
  });

  group('AgentControlService', () {
    late Directory directory;
    late Box<dynamic> box;
    late ConfigService store;
    late PayloadConfig config;
    late _FakeGenerationPort port;
    late AgentControlService service;
    late List<String> activities;
    late int replacedCount;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('casrand-agent-test-');
      Hive.init(directory.path);
      box = await Hive.openBox<dynamic>('savedBox');
      store = ConfigService();
      final loaded = await store.loadSavedConfigFromBox(box);
      config = PayloadConfig.fromJson(loaded);
      config.settings.updatePrimaryApiKey('pst-secret-token');
      config.settings.proxy = 'http://127.0.0.1:7890';
      port = _FakeGenerationPort();
      activities = [];
      replacedCount = 0;
      service = AgentControlService(
        payloadConfig: () => config,
        configService: () => store,
        generation: () => port,
        onActivity: activities.add,
        onConfigReplaced: () => replacedCount++,
        pollInterval: const Duration(milliseconds: 5),
      );
    });

    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('never exposes credentials or request destinations', () async {
      final result = await service.call('get_config', {});
      final text = json.encode(result.data);
      expect(text, isNot(contains('pst-secret-token')));
      final settings = (result.data as Map)['settings'] as Map;
      for (final key in protectedSettingKeys) {
        expect(settings.containsKey(key), isFalse, reason: key);
      }
      final exported = await service.call('export_config', {});
      expect(json.encode(exported.data), isNot(contains('pst-secret-token')));
    });

    test('update_config edits, saves and refreshes the live configuration',
        () async {
      var notified = 0;
      config.addListener(() => notified++);
      await service.call('update_config', {
        'patch': {
          'param_config': {'steps': 17},
        },
        'operations': [
          {'op': 'set', 'path': '/settings/file_name_prefix_key', 'value': 'k'},
        ],
      });
      expect(config.paramConfig.steps, 17);
      expect(config.settings.fileNamePrefixKey, 'k');
      expect(notified, greaterThan(0));
      expect(replacedCount, 1);
      expect(activities, ['update_config']);
      // Credentials and proxy survive the round trip.
      expect(config.settings.apiKey, 'pst-secret-token');
      expect(config.settings.proxy, 'http://127.0.0.1:7890');
      await store.flush();
      final saved = json.decode(box.get('savedConfig-${store.currentUuid}'));
      expect(saved['param_config']['steps'], 17);
      expect(saved['settings']['api_key'], 'pst-secret-token');
    });

    test('protected settings cannot be changed', () async {
      for (final key in ['api_key', 'api_base_url', 'proxy']) {
        await expectLater(
          service.call('update_config', {
            'patch': {
              'settings': {key: 'https://evil.example'},
            },
          }),
          throwsA(isA<AgentControlException>()
              .having((e) => e.code, 'code', 'protected_setting')),
        );
      }
      expect(config.settings.apiKey, 'pst-secret-token');
    });

    test('invalid configurations are rejected without changing anything',
        () async {
      final before = json.encode(config.toJson());
      await expectLater(
        service.call('update_config', {
          'patch': {'prompt_config': 'not an object'},
        }),
        throwsA(isA<AgentControlException>()),
      );
      expect(json.encode(config.toJson()), before);
    });

    test('prompt tree lists comment paths and set_prompt_node edits by path',
        () async {
      final tree = await service.call('get_prompt_tree', {});
      final roots = (tree.data as Map)['roots'] as List;
      final nodes = (roots.first as Map)['nodes'] as List;
      final artist = nodes.cast<Map>().firstWhere(
            (node) => (node['path'] as String).endsWith('/画师'),
          );
      expect(artist['pointer'], startsWith('/prompt_config/prompts/'));

      final result = await service.call('set_prompt_node', {
        'node': '画师',
        'changes': {
          'strs': 'artist:a, artist:b\nartist:c',
          'selectionMethod': 'single',
        },
      });
      expect((result.data as Map)['pointer'], artist['pointer']);
      final live = getAtJsonPointer(
        config.toJson(),
        artist['pointer'] as String,
      ) as Map;
      expect(live['strs'], ['artist:a, artist:b', 'artist:c']);

      await expectLater(
        service.call('set_prompt_node', {
          'node': '画师',
          'changes': {'bogus': 1},
        }),
        throwsA(isA<AgentControlException>()),
      );
      await expectLater(
        service.call('set_prompt_node', {
          'node': 'does-not-exist',
          'changes': {'enabled': false},
        }),
        throwsA(isA<AgentControlException>()
            .having((e) => e.code, 'code', 'not_found')),
      );
    });

    test('edits are refused while generating', () async {
      port.active = true;
      await expectLater(
        service.call('update_config', {
          'patch': {
            'param_config': {'steps': 5},
          },
        }),
        throwsA(isA<AgentControlException>()
            .having((e) => e.status, 'status', 409)),
      );
      await expectLater(
        service.call('start_generation', {}),
        throwsA(isA<AgentControlException>()
            .having((e) => e.code, 'code', 'generation_in_progress')),
      );
    });

    test('saved configurations can be listed, copied and switched', () async {
      final firstUuid = store.currentUuid;
      final saved = await service.call('save_config_as', {'title': 'Copy A'});
      final copyUuid = (saved.data as Map)['uuid'] as String;
      await service.call('update_config', {
        'patch': {
          'param_config': {'steps': 33},
        },
      });
      await service.call('switch_config', {'title': 'Copy A'});
      expect(store.currentUuid, copyUuid);
      expect(config.paramConfig.steps, isNot(33));
      await service.call('switch_config', {'uuid': firstUuid});
      expect(config.paramConfig.steps, 33);

      final listed = await service.call('list_configs', {});
      final titles = ((listed.data as Map)['configs'] as List)
          .map((entry) => (entry as Map)['title'])
          .toList();
      expect(titles, contains('Copy A'));

      await service.call('rename_config', {
        'uuid': copyUuid,
        'new_title': 'Copy B',
      });
      await service.call('delete_config', {'title': 'Copy B'});
      expect(store.configIndex.containsKey(copyUuid), isFalse);
      await expectLater(
        service.call('delete_config', {'uuid': firstUuid}),
        throwsA(isA<AgentControlException>()),
      );
    });

    test('import_config can replace the current config or add a new one',
        () async {
      final exported = (await service.call('export_config', {})).data
          as Map<String, dynamic>;
      exported['param_config']['steps'] = 11;
      await service.call('import_config', {'config': exported});
      expect(config.paramConfig.steps, 11);
      expect(config.settings.apiKey, 'pst-secret-token');

      exported['param_config']['steps'] = 12;
      final added = await service.call('import_config', {
        'config': exported,
        'mode': 'save_as_new',
        'title': 'Imported',
      });
      final uuid = (added.data as Map)['uuid'] as String;
      expect(store.configIndex[uuid]?.title, 'Imported');
      expect(config.paramConfig.steps, 11);
    });

    test('start_generation applies the count and waits for the results',
        () async {
      final identity = Object();
      port.onStart = () {
        Timer(const Duration(milliseconds: 20), () {
          port.finishWith(AgentResultView(
            identity: identity,
            status: 'succeeded',
            title: 'result.png',
            info: '',
            imageBytes: _png(64, 32),
            currentFilePath: '/tmp/session.png',
            storageStatus: 'encoding',
          ));
        });
        // JPG conversion finishes after the batch itself has ended.
        Timer(const Duration(milliseconds: 80), () {
          port.views[0] = _result(identity, bytes: _png(64, 32));
        });
      };
      final result = await service.call('start_generation', {
        'count': 1,
        'wait': true,
        'timeout_sec': 5,
      });
      final data = result.data as Map;
      expect(config.generationCount, 1);
      expect(data['started'], isTrue);
      final results = data['results'] as List;
      expect(results, hasLength(1));
      expect((results.single as Map)['file_path'], '/tmp/result.png');
      expect((results.single as Map)['details']['seed'], 42);
      expect(activities, contains('start_generation'));

      final image = await service.call('get_result_image', {});
      expect(image.images.single.mimeType, 'image/jpeg');
      final full = await service.call('get_result_image', {
        'id': (results.single as Map)['id'],
        'size': 'full',
      });
      expect(full.images.single.mimeType, 'image/png');
    });

    test('a generator that does not start is reported as an error', () async {
      port.refuseStart = true;
      await expectLater(
        service.call('start_generation', {}),
        throwsA(isA<AgentControlException>()
            .having((e) => e.code, 'code', 'start_failed')),
      );
    });

    test('stop_generation stops a running batch', () async {
      port.active = true;
      final result = await service.call('stop_generation', {});
      expect((result.data as Map)['was_generating'], isTrue);
      expect(port.active, isFalse);
    });

    test('reference images load from a file path', () async {
      final file = File('${directory.path}/base.png');
      await file.writeAsBytes(_png(1024, 768));
      final result = await service.call('add_reference_image', {
        'kind': 'i2i_base',
        'path': file.path,
        'strength': 0.5,
      });
      expect(config.i2iConfig.hasImage, isTrue);
      expect(config.i2iEnabled, isTrue);
      expect(config.i2iConfig.strength, 0.5);
      expect(((result.data as Map)['i2i'] as Map)['has_image'], isTrue);

      await service.call('clear_reference_images', {'kind': 'i2i_base'});
      expect(config.i2iConfig.hasImage, isFalse);

      await expectLater(
        service.call('add_reference_image', {
          'kind': 'vibe',
          'path': '${directory.path}/missing.png',
        }),
        throwsA(isA<AgentControlException>()
            .having((e) => e.code, 'code', 'not_found')),
      );
    });
  });

  group('AgentControlServer', () {
    late AgentControlServer server;
    late HttpClient client;
    late Uri base;
    const token = 'test-token';

    setUp(() async {
      // The test binding replaces HttpClient with a fake; talk to the real
      // loopback server instead.
      HttpOverrides.global = null;
      final port = _FakeGenerationPort();
      final store = ConfigService()
        ..currentUuid = 'current'
        ..configIndex = {};
      final config = PayloadConfig.fromJson(
        json.decode(await rootBundle.loadString('assets/json/example.json')),
      );
      final service = AgentControlService(
        payloadConfig: () => config,
        configService: () => store,
        generation: () => port,
      );
      server = AgentControlServer(
        service: service,
        token: token,
        serverVersion: '9.9.9',
      );
      final bound = await server.start();
      base = Uri.parse('http://127.0.0.1:$bound');
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
    });

    Future<(int, Object?)> send(
      String method,
      String path, {
      Object? body,
      Map<String, String> headers = const {
        'authorization': 'Bearer $token',
      },
    }) async {
      final request = await client.openUrl(method, base.resolve(path));
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(json.encode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text.isEmpty ? null : json.decode(text));
    }

    test('health is public, everything else needs the token', () async {
      final (healthStatus, health) = await send('GET', '/health', headers: {});
      expect(healthStatus, 200);
      expect((health as Map)['version'], '9.9.9');
      final (status, _) = await send('GET', '/api/v1/status', headers: {});
      expect(status, 401);
      final (wrong, _) = await send('GET', '/api/v1/status',
          headers: {'authorization': 'Bearer nope'});
      expect(wrong, 401);
      final (ok, data) = await send('GET', '/api/v1/status');
      expect(ok, 200);
      expect((data as Map)['generating'], isFalse);
    });

    test('foreign browser origins are rejected', () async {
      final (status, _) = await send('GET', '/api/v1/status', headers: {
        'authorization': 'Bearer $token',
        'origin': 'https://evil.example',
      });
      expect(status, 403);
    });

    test('MCP initialize, tools/list and tools/call', () async {
      final (initStatus, init) = await send('POST', '/mcp', body: {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
          'clientInfo': {'name': 'test', 'version': '1'},
        },
      });
      expect(initStatus, 200);
      expect((init as Map)['result']['protocolVersion'], '2025-06-18');
      expect(init['result']['capabilities']['tools'], isNotNull);

      final (notifyStatus, _) = await send('POST', '/mcp', body: {
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(notifyStatus, 202);

      final (_, list) = await send('POST', '/mcp', body: {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
      });
      final names = ((list as Map)['result']['tools'] as List)
          .map((tool) => (tool as Map)['name'])
          .toSet();
      expect(
        names,
        containsAll([
          'get_status',
          'update_config',
          'set_prompt_node',
          'start_generation',
          'get_result_image',
        ]),
      );

      final (_, call) = await send('POST', '/mcp', body: {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'get_status', 'arguments': {}},
      });
      final result = (call as Map)['result'] as Map;
      expect(result['isError'], isFalse);
      expect(result['structuredContent']['generating'], isFalse);

      final (_, failed) = await send('POST', '/mcp', body: {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'get_result_image',
          'arguments': {},
        },
      });
      expect((failed as Map)['result']['isError'], isTrue);

      final (_, unknown) = await send('POST', '/mcp', body: {
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'nope',
      });
      expect((unknown as Map)['error']['code'], -32601);

      final (getStatus, _) = await send('GET', '/mcp');
      expect(getStatus, 405);
    });

    test('REST tool calls report errors with status codes', () async {
      final (ok, data) = await send('POST', '/api/v1/tools/get_config', body: {
        'pointer': '/param_config/steps',
      });
      expect(ok, 200);
      expect((data as Map)['result'], isA<int>());
      final (missing, error) =
          await send('POST', '/api/v1/tools/does_not_exist', body: {});
      expect(missing, 404);
      expect((error as Map)['error'], 'unknown_tool');
    });
  });

  group('AgentControlController', () {
    test('writes and removes the discovery file around the server', () async {
      final directory =
          await Directory.systemTemp.createTemp('casrand-agent-discovery-');
      final preferences = _MemoryPreferences();
      final controller = AgentControlController(
        preferences: preferences,
        appVersion: '1.0.0',
        preferredPort: 0,
        discoveryDirectory: () async => directory,
        service: (_) => AgentControlService(
          payloadConfig: () => throw UnimplementedError(),
          configService: () => throw UnimplementedError(),
          generation: () => _FakeGenerationPort(),
        ),
      );
      await controller.setEnabled(true);
      expect(controller.isRunning, isTrue);
      final file = File('${directory.path}/$agentControlDiscoveryFileName');
      final discovery = json.decode(await file.readAsString()) as Map;
      expect(discovery['mcp_url'], controller.mcpUrl);
      expect(discovery['token'], preferences.token);
      expect(controller.claudeCodeCommand,
          contains('Bearer ${preferences.token}'));

      final oldToken = preferences.token;
      await controller.regenerateToken();
      expect(preferences.token, isNot(oldToken));
      expect(controller.isRunning, isTrue);

      await controller.setEnabled(false);
      expect(controller.isRunning, isFalse);
      expect(await file.exists(), isFalse);
      expect(preferences.enabled, isFalse);
      controller.dispose();
      await directory.delete(recursive: true);
    });
  });

  group('AgentControlSettingsTiles', () {
    late Map<String, dynamic> translations;

    setUpAll(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/shared_preferences'),
        (call) async => call.method == 'getAll' ? <String, Object>{} : true,
      );
      await EasyLocalization.ensureInitialized();
      translations =
          json.decode(await rootBundle.loadString('assets/l10n/en.json'))
              as Map<String, dynamic>;
    });

    testWidgets('switch starts the server and reveals connection tiles',
        (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('casrand-agent-tiles-'),
      );
      final controller = AgentControlController(
        preferences: _MemoryPreferences(),
        appVersion: '1.0.0',
        preferredPort: 0,
        discoveryDirectory: () async => directory!,
        service: (_) => AgentControlService(
          payloadConfig: () => throw UnimplementedError(),
          configService: () => throw UnimplementedError(),
          generation: () => _FakeGenerationPort(),
        ),
      );
      await tester.pumpWidget(EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'test',
        assetLoader: _MapAssetLoader(translations),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        saveLocale: false,
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(
              body: AgentControlSettingsTiles(controller: controller),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Allow agent control'), findsOneWidget);
      expect(find.byKey(const Key('agent-control-copy-command')), findsNothing);

      await tester.runAsync(() => controller.setEnabled(true));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('agent-control-copy-command')), findsOneWidget);
      expect(find.textContaining(controller.mcpUrl!), findsOneWidget);

      await tester.runAsync(() => controller.setEnabled(false));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agent-control-copy-command')), findsNothing);
      controller.dispose();
      await tester.runAsync(() => directory!.delete(recursive: true));
    });
  });
}

class _MapAssetLoader extends AssetLoader {
  const _MapAssetLoader(this.translations);

  final Map<String, dynamic> translations;

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async =>
      translations;
}

class _MemoryPreferences implements AgentControlPreferences {
  @override
  bool enabled = false;

  @override
  String? token;
}
