import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class _RecordingFiles extends FileService {
  final savedBytes = <Uint8List>[];
  final savedNames = <String>[];

  @override
  Future<String?> savePictureToFile(
      Uint8List bytes, String name, String dir) async {
    savedBytes.add(Uint8List.fromList(bytes));
    savedNames.add(name);
    return '/fixture/$name';
  }

  @override
  String generateRandomString() => 'fixture';
}

Uint8List _png(int red) {
  final image = img.Image(width: 64, height: 64, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(red, 30, 50));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _zip(Uint8List png) {
  final archive = Archive()
    ..addFile(ArchiveFile('image_0.png', png.length, png));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// The external HTTP boundary is controlled; ApiService, its deadlines,
/// GenerationPageViewmodel, scheduler, ZIP handling and storage are real.
class _Transport {
  final requests = <http.BaseRequest>[];
  final pending = <Completer<http.StreamedResponse>>[];
  http.Client newClient(String proxy) => _RouteClient(this);

  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    final result = Completer<http.StreamedResponse>();
    pending.add(result);
    return result.future;
  }

  void image(int index, Uint8List png) => bytes(index, _zip(png));
  void bytes(int index, Uint8List bytes) {
    pending[index].complete(http.StreamedResponse(Stream.value(bytes), 200));
  }
}

class _RouteClient extends http.BaseClient {
  _RouteClient(this.transport);
  final _Transport transport;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      transport.send(request);
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void _settings({int count = 1, bool parallel = false}) {
  final settings = GetIt.I<PayloadConfig>().settings;
  settings
    ..debugApiEnabled = true
    ..debugApiPath = 'http://127.0.0.1:1/generate-image'
    ..generationCount = count
    ..generationIntervalSec = 0
    ..apiKey = 'TOKEN_A'
    ..parallelApiEnabled = parallel
    ..apiTokens = [
      ApiTokenConfig(label: 'Account A', token: 'TOKEN_A'),
      ApiTokenConfig(label: 'Account B', token: 'TOKEN_B'),
    ];
}

void main() {
  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton(CommandStatus());
    GetIt.I.registerSingleton(NavigationRequest());
    GetIt.I.registerSingleton(PayloadConfig(
      rootPromptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: ['fixture'], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(
        sizes: const [GenerationSize(width: 832, height: 1216)],
        randomSeed: false,
        seed: 42,
      ),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    ));
  });
  tearDown(() async {
    await GetIt.I.reset();
  });

  testWidgets('build117 disconnect retries automatically on the same card',
      (tester) async {
    _settings();
    final transport = _Transport();
    final api = ApiService(clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    final card = vm.commandList.single;
    final original = (transport.requests.single as http.Request).body;
    transport.pending.single.completeError(http.ClientException('closed'));
    await _pump(tester);
    expect(vm.commandStatus.outcomeUnknownFor(card), isNull);
    expect(transport.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 6));
    await _pump(tester);
    expect(transport.requests, hasLength(2));
    expect((transport.requests.last as http.Request).body, original);
    final png = _png(33);
    transport.image(1, png);
    await _pump(tester);
    expect(files.savedBytes, [png]);
    expect(vm.commandList.single, same(card));
    expect(card.value.imageBytes, png);
  });

  testWidgets('build117 deadline retries and ignores the expired response',
      (tester) async {
    _settings();
    final transport = _Transport();
    final api = ApiService(
        requestTimeout: const Duration(seconds: 2),
        clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    final card = vm.commandList.single;
    await tester.pump(const Duration(seconds: 2));
    await _pump(tester);
    expect(vm.commandStatus.outcomeUnknownFor(card), isNull);
    expect(vm.commandStatus.isGenerationActive.value, isTrue);
    await tester.pump(const Duration(seconds: 5));
    await _pump(tester);
    expect(transport.requests, hasLength(2));
    transport.image(0, _png(10));
    await _pump(tester);
    expect(files.savedBytes, isEmpty);
    transport.image(1, _png(11));
    await _pump(tester);
    expect(files.savedBytes, [_png(11)]);
    expect(vm.commandList.single, same(card));
    expect(vm.commandStatus.currentGenerationCount, 1);
  });

  testWidgets(
      'build117 all accounts survive intermittent disconnects and successes reset counts',
      (tester) async {
    _settings(count: 10, parallel: true);
    final transport = _Transport();
    final api = ApiService(clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    for (var round = 0; round < 5; round++) {
      final start = round * 4;
      expect(transport.requests, hasLength(start + 2));
      expect(
          transport.requests
              .skip(start)
              .map((r) => r.headers['authorization'])
              .toSet(),
          {'Bearer TOKEN_A', 'Bearer TOKEN_B'});
      for (var i = start; i < start + 2; i++) {
        transport.pending[i]
            .completeError(http.ClientException('disconnected'));
      }
      await _pump(tester);
      expect(vm.commandStatus.isGenerationActive.value, isTrue);
      await tester.pump(const Duration(seconds: 5));
      await _pump(tester);
      expect(transport.requests, hasLength(start + 4),
          reason:
              'Both accounts must return after their first-failure delay on every round.');
      expect(
          transport.requests
              .skip(start + 2)
              .map((r) => r.headers['authorization'])
              .toSet(),
          {'Bearer TOKEN_A', 'Bearer TOKEN_B'});
      transport.image(start + 2, _png(round * 2));
      transport.image(start + 3, _png(round * 2 + 1));
      await _pump(tester);
    }
    expect(files.savedBytes, hasLength(10));
    expect(vm.commandStatus.currentGenerationCount, 10);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
    expect(
        vm.commandList
            .every((c) => vm.commandStatus.outcomeUnknownFor(c) == null),
        isTrue);
  });

  for (final failure in ['disconnect', 'unauthorized', 'rate limited']) {
    testWidgets('build117 $failure pauses only after five consecutive failures',
        (tester) async {
      _settings();
      final transport = _Transport();
      final api = ApiService(clientFactory: transport.newClient);
      final vm = GenerationPageViewmodel(
          apiService: api, fileService: _RecordingFiles());
      addTearDown(vm.dispose);
      addTearDown(api.close);
      vm.startGeneration();
      await _pump(tester);
      for (var attempt = 0; attempt < 5; attempt++) {
        expect(transport.requests, hasLength(attempt + 1));
        if (failure == 'disconnect') {
          transport.pending[attempt]
              .completeError(http.ClientException('closed'));
        } else {
          transport.pending[attempt].complete(http.StreamedResponse(
              Stream.value(utf8.encode(failure)),
              failure == 'unauthorized' ? 401 : 429,
              headers: {'retry-after': '60'}));
        }
        await _pump(tester);
        if (attempt < 4) {
          expect(vm.commandStatus.isGenerationActive.value, isTrue);
          final delay = attempt == 0 ? 5 : 15;
          await tester.pump(Duration(seconds: delay - 1));
          expect(transport.requests, hasLength(attempt + 1));
          await tester.pump(const Duration(seconds: 1));
          await _pump(tester);
        }
      }
      expect(vm.commandStatus.isGenerationActive.value, isFalse);
      await tester.pump(const Duration(minutes: 2));
      await _pump(tester);
      expect(transport.requests, hasLength(5));
    });
  }

  testWidgets('build117 stop cancels automatic retry without another POST',
      (tester) async {
    _settings();
    final transport = _Transport();
    final api = ApiService(clientFactory: transport.newClient);
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFiles());
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    transport.pending.single.completeError(http.ClientException('closed'));
    await _pump(tester);
    vm.stopGeneration();
    await tester.pump(const Duration(minutes: 1));
    await _pump(tester);
    expect(transport.requests, hasLength(1));
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
  });

  testWidgets(
      'build117 Vibe disconnect clears failed extraction and retries generation',
      (tester) async {
    _settings();
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-4-5-full';
    final reference = VibeConfigV4(
        fileName: 'fixture.png', imageBytes: _png(28), referenceStrength: 0.6);
    config.vibeConfigListV4.add(reference);
    config.setVibeEnabled(true);
    final transport = _Transport();
    final api = ApiService(clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    expect(transport.requests.single.url.path, contains('encode-vibe'));
    transport.pending.single.completeError(http.ClientException('closed'));
    await _pump(tester);
    await tester.pump(const Duration(seconds: 5));
    await _pump(tester);
    expect(transport.requests, hasLength(2));
    expect(transport.requests.last.url.path, contains('encode-vibe'));
    transport.bytes(1, Uint8List.fromList([10, 20, 30]));
    await _pump(tester);
    expect(transport.requests, hasLength(3));
    expect(transport.requests.last.url.path, contains('generate-image'));
    expect(reference.encodingFor('nai-diffusion-4-5-full'),
        base64Encode([10, 20, 30]));
    transport.image(2, _png(31));
    await _pump(tester);
    expect(files.savedBytes, hasLength(1));
  });
  testWidgets(
      'Stop blocks new POSTs but still saves an already submitted response',
      (tester) async {
    _settings(count: 3);
    final transport = _Transport();
    final api = ApiService(clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    expect(transport.requests, hasLength(1));
    vm.stopGeneration();
    expect(vm.commandStatus.isStopping.value, isTrue);
    final png = _png(27);
    transport.image(0, png);
    await _pump(tester);
    await tester.pump(const Duration(seconds: 30));
    await _pump(tester);
    expect(transport.requests, hasLength(1));
    expect(files.savedBytes.single, png);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
    expect(vm.commandStatus.currentGenerationCount, 1);
  });
}
