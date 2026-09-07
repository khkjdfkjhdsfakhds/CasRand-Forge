import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;

Future<void> _skipPreparationFeedbackBarrier() async {}

class _RecordingFileService extends FileService {
  final List<String> savedNames = [];
  final List<Uint8List> savedBytes = [];

  @override
  Future<String?> savePictureToFile(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async {
    savedNames.add(fileName);
    savedBytes.add(Uint8List.fromList(bytes));
    return '/test/$fileName';
  }

  @override
  String generateRandomString() => 'result';
}

Uint8List directorResponseZip(List<Uint8List> images) {
  final archive = Archive();
  for (final (index, bytes) in images.indexed) {
    archive.addFile(ArchiveFile('image_$index.png', bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

class _NetworkAuditApi extends ApiService {
  final requests = <ApiRequest>[];
  final pending = <Completer<ApiResponse>>[];
  @override
  Future<ApiResponse> fetchData(ApiRequest r) {
    requests.add(r);
    final c = Completer<ApiResponse>();
    pending.add(c);
    return c.future;
  }

  void success(int i) => pending[i].complete(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(
            img.encodePng(img.Image(width: 64, height: 64, numChannels: 3)))
      ])));
  void successSized(int i) {
    final p = requests[i].payload['parameters'];
    final png = Uint8List.fromList(img.encodePng(
        img.Image(width: p['width'], height: p['height'], numChannels: 3)));
    pending[i]
        .complete(ApiResponse(status: '200', data: directorResponseZip([png])));
  }

  void error(int i, {String status = '503'}) => pending[i].complete(ApiResponse(
      status: status,
      data:
          Uint8List.fromList(utf8.encode('{"message":"synthetic failure"}'))));
}

class _NetworkAuditHttp extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final pending = <Completer<http.StreamedResponse>>[];
  int closed = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) {
    requests.add(r);
    final c = Completer<http.StreamedResponse>();
    pending.add(c);
    return c.future;
  }

  @override
  void close() {
    closed++;
  }

  void respond(int i,
      {int status = 200, Map<String, String> headers = const {}}) {
    final bytes = status == 200
        ? directorResponseZip([
            Uint8List.fromList(
                img.encodePng(img.Image(width: 64, height: 64, numChannels: 3)))
          ])
        : utf8.encode('{"message":"synthetic HTTP error"}');
    pending[i].complete(
        http.StreamedResponse(Stream.value(bytes), status, headers: headers));
  }
}

void _networkSettings({int count = 2, bool parallel = true}) {
  final s = GetIt.I<PayloadConfig>().settings;
  s
    ..debugApiEnabled = true
    ..debugApiPath = 'http://127.0.0.1:1/fixture'
    ..generationCount = count
    ..generationIntervalSec = 0
    ..apiKey = 'TOKEN_A'
    ..parallelApiEnabled = parallel;
  s.apiTokens = [
    ApiTokenConfig(label: 'A', token: 'TOKEN_A'),
    ApiTokenConfig(label: 'B', token: 'TOKEN_B')
  ];
}

Future<void> _networkPump(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 1));
  }
}

Future<void> _until(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 80 && !ready(); i++) {
    await _networkPump(t);
  }
  expect(ready(), isTrue,
      reason: 'Controlled asynchronous work must settle before assertions');
}

void main() {
  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton(CommandStatus());
    GetIt.instance.registerSingleton(NavigationRequest());
    GetIt.instance.registerSingleton(
      PayloadConfig(
        rootPromptConfig: PromptConfig(strs: [], prompts: []),
        negativePromptConfig: PromptConfig(
          shuffled: false,
          strs: ['test negative prompt'],
          prompts: [],
        ),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
          randomSeed: true,
          seed: 42,
        ),
        settings: Settings.fromJson({
          'generation_count': 0,
          'generation_interval': 10,
        }),
        overridePrompt: '',
        useOverridePrompt: false,
        useCharacterPromptWithOverride: false,
      ),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  testWidgets(
      'NET-01 healthy idle worker takes over after faulty worker pauses',
      (tester) async {
    _networkSettings();
    final api = _NetworkAuditApi();
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await _networkPump(tester);
    expect(api.requests.length, 2);
    api.success(1);
    await _networkPump(tester);
    for (var n = 0; n < 5; n++) {
      api.error(n == 0 ? 0 : n + 1);
      await _networkPump(tester);
      if (n < 4) {
        await tester.pump(Duration(seconds: n == 0 ? 5 : 15));
        await _networkPump(tester);
      }
    }
    await tester.pump(const Duration(minutes: 5));
    await _networkPump(tester);
    final calls = api.requests.map((r) => r.headers['authorization']).toList();
    final active = vm.commandStatus.isGenerationActive.value;
    final complete = vm.commandStatus.currentGenerationCount;
    final waiting = vm.commandStatus.isWaitingForNextGeneration.value;
    vm.stopGeneration();
    await _networkPump(tester);
    vm.dispose();
    debugPrint(
        'NET01 calls=$calls active=$active completed=$complete waiting=$waiting');
    expect(calls.where((x) => x == 'Bearer TOKEN_B').length, greaterThan(1),
        reason:
            'Healthy B should pick pending work rather than leave a stuck batch');
  });

  for (final status in ['401', '402', '403']) {
    testWidgets(
        'Account HTTP $status pauses immediately while healthy account continues',
        (tester) async {
      _networkSettings(count: 3);
      final api = _NetworkAuditApi();
      final vm = GenerationPageViewmodel(
          apiService: api, fileService: _RecordingFileService());
      vm.startGeneration();
      await _networkPump(tester);
      api.error(0, status: status);
      await _networkPump(tester);
      for (var i = 1; i <= 3; i++) {
        api.success(i);
        await _networkPump(tester);
      }
      expect(
          api.requests
              .where((r) => r.headers['authorization'] == 'Bearer TOKEN_A'),
          hasLength(1));
      expect(vm.commandStatus.currentGenerationCount, 3);
      expect(vm.commandStatus.isGenerationActive.value, false);
      vm.dispose();
    });
  }
  testWidgets('NET-C01 slow A does not block B from completing later tasks',
      (tester) async {
    _networkSettings(count: 4);
    final api = _NetworkAuditApi();
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await _networkPump(tester);
    for (var i = 1; i < 4; i++) {
      api.success(i);
      await _networkPump(tester);
    }
    expect(api.requests.length, 4);
    expect(vm.commandStatus.currentGenerationCount, 3);
    expect(
        api.requests
            .skip(1)
            .every((r) => r.headers['authorization'] == 'Bearer TOKEN_B'),
        isTrue);
    api.success(0);
    await _networkPump(tester);
    expect(vm.commandStatus.currentGenerationCount, 4);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
    vm.dispose();
  });
  testWidgets('NET-02 timeout must not silently repeat unknown-outcome POST',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final transport = _NetworkAuditHttp();
    final api = ApiService(
        requestTimeout: const Duration(seconds: 1),
        clientFactory: (_) => transport);
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await _networkPump(tester);
    expect(transport.requests.length, 1);
    await tester.pump(const Duration(milliseconds: 1001));
    await _networkPump(tester);
    final error = vm.commandList.first.value.info;
    await tester.pump(const Duration(seconds: 5));
    await _networkPump(tester);
    final count = transport.requests.length;
    if (transport.requests.length > 1) {
      transport.respond(1);
      await _networkPump(tester);
    }
    transport.respond(0);
    await _networkPump(tester);
    debugPrint(
        'NET02 automaticPosts=$count error=$error resultCards=${vm.commandList.length} successes=${vm.commandStatus.currentGenerationCount}');
    vm.dispose();
    api.close();
    expect(count, 1,
        reason: 'Client timeout is not proof the server failed to generate');
  });
  testWidgets('NET-03 HTTP Retry-After is respected before trying again',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final transport = _NetworkAuditHttp();
    final api = ApiService(clientFactory: (_) => transport);
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await _networkPump(tester);
    transport.respond(0, status: 429, headers: {'retry-after': '60'});
    await _networkPump(tester);
    await tester.pump(const Duration(seconds: 5));
    await _networkPump(tester);
    final calls = transport.requests.length;
    expect(vm.commandStatus.waitingFor(vm.commandList.single), isNotNull);
    expect(vm.commandStatus.waitingFor(vm.commandList.single)!.message,
        isNot(contains('{seconds}')));
    vm.stopGeneration();
    expect(vm.commandStatus.waitingFor(vm.commandList.single), isNull);
    if (calls > 1) {
      transport.respond(1);
      await _networkPump(tester);
    }
    vm.dispose();
    api.close();
    debugPrint('NET03 Retry-After=60, POST count at t+5s=$calls');
    expect(calls, 1);
  });
  testWidgets(
      'NET-07 stable task card follows retry execution and account label',
      (tester) async {
    _networkSettings(count: 1);
    final api = _NetworkAuditApi();
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await _networkPump(tester);
    final card = vm.commandList.single;
    api.error(0);
    await _networkPump(tester);
    expect(vm.commandStatus.waitingFor(card), isNotNull);
    await tester.pump(const Duration(seconds: 5));
    await _networkPump(tester);
    expect(vm.commandList.single, same(card));
    expect(vm.commandStatus.isExecuting(card), true);
    expect(vm.commandStatus.waitingFor(card), isNull);
    api.success(1);
    await _networkPump(tester);
    expect(vm.commandStatus.isExecuting(card), false);
    expect(card.value.imageBytes, isNotNull);
    vm.dispose();
  });
  testWidgets('NET-C02 stop during retries blocks further POSTs',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final api = _NetworkAuditApi();
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await _networkPump(tester);
    api.error(0);
    await _networkPump(tester);
    vm.stopGeneration();
    await tester.pump(const Duration(minutes: 1));
    await _networkPump(tester);
    expect(api.requests.length, 1);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
    vm.dispose();
  });

  testWidgets(
      'NET-04 split inpaint does not re-request an already successful tile',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final config = GetIt.I<PayloadConfig>();
    config.i2iEnabled = true;
    final batch = await tester.runAsync(() async {
      final base = img.Image(width: 1920, height: 1080, numChannels: 3);
      final mask = img.Image(width: 1920, height: 1080, numChannels: 3);
      img.fillRect(mask,
          x1: 0,
          y1: 784,
          x2: 191,
          y2: 1079,
          color: img.ColorRgb8(255, 255, 255));
      img.fillRect(mask,
          x1: 1728,
          y1: 0,
          x2: 1919,
          y2: 287,
          color: img.ColorRgb8(255, 255, 255));
      config.i2iConfig.setImage(Uint8List.fromList(img.encodePng(base)));
      config.i2iConfig.setMask(Uint8List.fromList(img.encodePng(mask)), []);
      return PrepareI2iRequestUseCase(config: config.i2iConfig)
          .planBatch(targetWidth: 832, targetHeight: 1216);
    });
    expect(batch!.tileCount, 2);
    final api = _NetworkAuditApi();
    final files = _RecordingFileService();
    final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: files,
        preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
        prepareI2iBatch: (
                {required config,
                required targetWidth,
                required targetHeight,
                required transparentBackground}) async =>
            batch);
    vm.startGeneration();
    await _networkPump(tester);
    api.successSized(0);
    // The next source is now rebuilt on a worker isolate.
    await _until(tester, () => api.requests.length == 2);
    expect(api.requests.length, 2);
    api.error(1);
    await _until(
        tester, () => vm.commandStatus.isWaitingForNextGeneration.value);
    await tester.pump(const Duration(seconds: 5));
    await _until(tester, () => api.requests.length == 3);
    final count = api.requests.length;
    final repeated = count > 2 &&
        jsonEncode(api.requests[2].payload) ==
            jsonEncode(api.requests[0].payload);
    expect(files.savedBytes, hasLength(1),
        reason: 'Successful partial tiles must be durably saved before retry');
    api.successSized(2);
    await _until(tester, () => !vm.commandStatus.isGenerationActive.value);
    await _until(tester, () => files.savedBytes.length == 2);
    expect(vm.commandStatus.currentGenerationCount, 1);
    vm.dispose();
    debugPrint(
        'NET04 tiles=${batch.tileCount} serial=${batch.serial} POSTsAfterRetry=$count repeatsSuccessfulTile=$repeated saved=${files.savedBytes.length}');
    expect(repeated, isFalse,
        reason: 'Successful paid tile should survive a different tile failure');
  });
  testWidgets(
      'NET-04 parallel split preserves sibling success when another tile fails',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final config = GetIt.I<PayloadConfig>();
    config.i2iEnabled = true;
    final batch = await tester.runAsync(() async {
      final base = img.Image(width: 1920, height: 1080, numChannels: 3);
      final mask = img.Image(width: 1920, height: 1080, numChannels: 3);
      img.fillRect(mask,
          x1: 0,
          y1: 784,
          x2: 191,
          y2: 1079,
          color: img.ColorRgb8(255, 255, 255));
      img.fillRect(mask,
          x1: 1728,
          y1: 0,
          x2: 1919,
          y2: 287,
          color: img.ColorRgb8(255, 255, 255));
      config.i2iConfig.setImage(Uint8List.fromList(img.encodePng(base)));
      config.i2iConfig.setMask(Uint8List.fromList(img.encodePng(mask)), []);
      return PrepareI2iRequestUseCase(config: config.i2iConfig)
          .planBatch(targetWidth: 832, targetHeight: 1216);
    });
    expect(batch!.tileCount, 2);
    final api = _NetworkAuditApi();
    final files = _RecordingFileService();
    final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: files,
        preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
        prepareI2iBatch: (
                {required config,
                required targetWidth,
                required targetHeight,
                required transparentBackground}) async =>
            I2iRequestBatch(
                plans: batch.plans,
                serial: false,
                summary: batch.summary,
                compositeBaseImageB64: batch.compositeBaseImageB64));
    vm.startGeneration();
    await _networkPump(tester);
    expect(api.requests, hasLength(2));
    api.successSized(0);
    await _networkPump(tester);
    expect(api.requests.length, 2);
    api.error(1);
    await _until(
        tester, () => vm.commandStatus.isWaitingForNextGeneration.value);
    await tester.pump(const Duration(seconds: 5));
    await _until(tester, () => api.requests.length == 3);
    final count = api.requests.length;
    final repeated = count > 2 &&
        jsonEncode(api.requests[2].payload) ==
            jsonEncode(api.requests[0].payload);
    expect(files.savedBytes, hasLength(1),
        reason: 'Successful partial tiles must be durably saved before retry');
    api.successSized(2);
    await _until(tester, () => !vm.commandStatus.isGenerationActive.value);
    await _until(tester, () => files.savedBytes.length == 2);
    expect(vm.commandStatus.currentGenerationCount, 1);
    vm.dispose();
    debugPrint(
        'NET04 tiles=${batch.tileCount} serial=${batch.serial} POSTsAfterRetry=$count repeatsSuccessfulTile=$repeated saved=${files.savedBytes.length}');
    expect(repeated, isFalse,
        reason: 'Successful paid tile should survive a different tile failure');
  });
  testWidgets('NET-04 stop retains paid tile and sends no next serial tile',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final config = GetIt.I<PayloadConfig>();
    config.i2iEnabled = true;
    final batch = await tester.runAsync(() async {
      final base = img.Image(width: 1920, height: 1080, numChannels: 3);
      final mask = img.Image(width: 1920, height: 1080, numChannels: 3);
      img.fillRect(mask,
          x1: 0,
          y1: 784,
          x2: 191,
          y2: 1079,
          color: img.ColorRgb8(255, 255, 255));
      img.fillRect(mask,
          x1: 1728,
          y1: 0,
          x2: 1919,
          y2: 287,
          color: img.ColorRgb8(255, 255, 255));
      config.i2iConfig.setImage(Uint8List.fromList(img.encodePng(base)));
      config.i2iConfig.setMask(Uint8List.fromList(img.encodePng(mask)), []);
      return PrepareI2iRequestUseCase(config: config.i2iConfig)
          .planBatch(targetWidth: 832, targetHeight: 1216);
    });
    expect(batch!.tileCount, 2);
    final api = _NetworkAuditApi();
    final files = _RecordingFileService();
    final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: files,
        preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
        prepareI2iBatch: (
                {required config,
                required targetWidth,
                required targetHeight,
                required transparentBackground}) async =>
            batch);
    vm.startGeneration();
    await _networkPump(tester);
    expect(api.requests, hasLength(1));
    vm.stopGeneration();
    api.successSized(0);
    await _until(tester, () => !vm.commandStatus.isGenerationActive.value);
    await _until(tester, () => files.savedBytes.length == 1);
    expect(api.requests, hasLength(1));
    expect(vm.commandStatus.currentGenerationCount, 0);
    expect(
        vm.commandList
            .any((c) => c.value.additionalInfo['completed_tiles'] == 1),
        isTrue);
    vm.dispose();
  });
  testWidgets('NET-05 stop during preparation prevents the unsent paid request',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final gate = Completer<void>();
    final config = GetIt.I<PayloadConfig>();
    config.i2iEnabled = true;
    config.i2iConfig.setPreparedImage(
        Uint8List.fromList(
            img.encodePng(img.Image(width: 64, height: 64, numChannels: 3))),
        width: 64,
        height: 64);
    final api = _NetworkAuditApi();
    final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: _RecordingFileService(),
        preparationFeedbackBarrier: () => gate.future,
        prepareI2iBatch: (
                {required config,
                required targetWidth,
                required targetHeight,
                required transparentBackground}) async =>
            null);
    vm.startGeneration();
    await _networkPump(tester);
    expect(api.requests, isEmpty);
    vm.stopGeneration();
    gate.complete();
    await _networkPump(tester);
    final count = api.requests.length;
    if (count > 0) {
      api.success(0);
      await _networkPump(tester);
    }
    vm.dispose();
    debugPrint('NET05 POSTs sent after Stop during preparation=$count');
    expect(count, 0);
  });

  testWidgets(
      'NET-02B Vibe timeout does not create an overlapping encoding request',
      (tester) async {
    _networkSettings(count: 1, parallel: false);
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-4-5-full';
    config.vibeConfigListV4.add(VibeConfigV4(
        fileName: 'fixture.png',
        imageBytes: Uint8List.fromList(
            img.encodePng(img.Image(width: 64, height: 64, numChannels: 3))),
        referenceStrength: 0.6));
    config.setVibeEnabled(true);
    final transport = _NetworkAuditHttp();
    final api = ApiService(clientFactory: (_) => transport);
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await _networkPump(tester);
    expect(transport.requests.length, 1);
    expect(transport.requests.first.url.path, contains('encode-vibe'));
    await tester.pump(const Duration(seconds: 121));
    await _networkPump(tester);
    await tester.pump(const Duration(seconds: 5));
    await _networkPump(tester);
    final calls = transport.requests.length;
    final closed = transport.closed;
    vm.stopGeneration();
    if (calls > 1) {
      transport.respond(1, status: 503);
      await _networkPump(tester);
    }
    transport.respond(0);
    await _networkPump(tester);
    vm.dispose();
    api.close();
    debugPrint(
        'NET02B Vibe calls=$calls transportClosedBeforeSecondResponse=$closed');
    expect(calls, 1,
        reason:
            'The original encoding HTTP request is still running after the shorter Vibe timeout');
  });
}
