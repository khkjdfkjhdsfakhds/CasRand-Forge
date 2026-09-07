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

  testWidgets(
      'unknown POST pauses without replay, then saves the original late result',
      (tester) async {
    _settings();
    final transport = _Transport();
    final api = ApiService(
        requestTimeout: const Duration(seconds: 1),
        clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    final originalCard = vm.commandList.single;
    await tester.pump(const Duration(seconds: 2));
    await _pump(tester);
    expect(vm.commandStatus.outcomeUnknownFor(originalCard), isNotNull);
    expect(vm.commandStatus.isExecuting(originalCard), isFalse);
    await tester.pump(const Duration(seconds: 30));
    await _pump(tester);
    expect(transport.requests, hasLength(1));
    expect(files.savedBytes, isEmpty);
    final png = _png(20);
    transport.image(0, png);
    await _pump(tester);
    expect(files.savedBytes, hasLength(1));
    expect(files.savedBytes.single, png);
    expect(vm.commandList.single, same(originalCard));
    expect(originalCard.value.imageBytes, png);
    expect(vm.commandStatus.outcomeUnknownFor(originalCard), isNull);
    expect(vm.commandStatus.currentGenerationCount, 1);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
  });

  testWidgets(
      'healthy account continues unsent tasks after another account becomes unknown',
      (tester) async {
    _settings(count: 4, parallel: true);
    final transport = _Transport();
    final api = ApiService(
        requestTimeout: const Duration(seconds: 1),
        clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    expect(transport.requests, hasLength(2));
    await tester.pump(const Duration(milliseconds: 500));
    transport.image(1, _png(21));
    await _pump(tester);
    expect(transport.requests, hasLength(3));
    await tester.pump(const Duration(milliseconds: 510));
    await _pump(tester);
    expect(vm.commandStatus.currentGenerationCount, 1);
    transport.image(2, _png(22));
    await _pump(tester);
    expect(transport.requests, hasLength(4));
    expect(transport.requests.skip(1).map((r) => r.headers['authorization']),
        everyElement('Bearer TOKEN_B'));
    transport.image(3, _png(23));
    await _pump(tester);
    expect(vm.commandStatus.currentGenerationCount, 3);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
    await tester.pump(const Duration(seconds: 15));
    await _pump(tester);
    expect(transport.requests, hasLength(4));
    transport.image(0, _png(24));
    await _pump(tester);
    expect(files.savedBytes, hasLength(4));
    expect(vm.commandStatus.currentGenerationCount, 4);
  });

  testWidgets('old-batch late success cannot complete or cancel a new batch',
      (tester) async {
    _settings();
    final transport = _Transport();
    final api = ApiService(
        requestTimeout: const Duration(seconds: 1),
        clientFactory: transport.newClient);
    final files = _RecordingFiles();
    final vm = GenerationPageViewmodel(apiService: api, fileService: files);
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    final oldCard = vm.commandList.single;
    final oldTimestamp = vm.commandStatus.generationTimestamp;
    await tester.pump(const Duration(seconds: 2));
    await _pump(tester);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
    vm.startGeneration();
    await _pump(tester);
    expect(transport.requests, hasLength(2));
    final newCommand = vm.currentCommand;
    expect(newCommand, isNotNull);
    expect(vm.commandStatus.generationTimestamp, isNot(oldTimestamp));
    transport.image(0, _png(25));
    await _pump(tester);
    expect(oldCard.value.imageBytes, _png(25));
    expect(files.savedBytes, hasLength(1));
    expect(vm.currentCommand, same(newCommand));
    expect(vm.commandStatus.currentGenerationCount, 0);
    expect(vm.commandStatus.isGenerationActive.value, isTrue);
    transport.image(1, _png(26));
    await _pump(tester);
    expect(files.savedBytes, hasLength(2));
    expect(vm.commandStatus.currentGenerationCount, 1);
    expect(vm.commandStatus.isGenerationActive.value, isFalse);
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

  testWidgets(
      'unknown Vibe keeps its late encoding on the exact original reference',
      (tester) async {
    _settings();
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-4-5-full';
    final original = VibeConfigV4(
        fileName: 'fixture.png', imageBytes: _png(28), referenceStrength: 0.6);
    config.vibeConfigListV4.add(original);
    config.setVibeEnabled(true);
    final transport = _Transport();
    final api = ApiService(
        requestTimeout: const Duration(seconds: 1),
        clientFactory: transport.newClient);
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFiles());
    addTearDown(vm.dispose);
    addTearDown(api.close);
    vm.startGeneration();
    await _pump(tester);
    expect(transport.requests.single.url.path, contains('encode-vibe'));
    await tester.pump(const Duration(seconds: 2));
    await _pump(tester);
    await tester.pump(const Duration(seconds: 30));
    await _pump(tester);
    expect(transport.requests, hasLength(1));
    final encoding = Uint8List.fromList([10, 20, 30]);
    transport.bytes(0, encoding);
    await _pump(tester);
    expect(
        original.encodingFor('nai-diffusion-4-5-full'), base64Encode(encoding));
    expect(transport.requests, hasLength(1),
        reason: 'Late preparation must not restart generation.');
  });
}
