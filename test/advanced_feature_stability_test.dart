import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:flutter_command/flutter_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'package:nai_casrand/data/use_cases/encode_vibe_use_case.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class _RecordingFailureApiService extends ApiService {
  final List<Map<String, dynamic>> payloads = [];

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    payloads.add(
      jsonDecode(jsonEncode(request.payload)) as Map<String, dynamic>,
    );
    return ApiResponse(
      status: '500',
      data: Uint8List.fromList(
        utf8.encode('{"statusCode":500,"message":"audit failure"}'),
      ),
    );
  }
}

class _SequenceApiService extends ApiService {
  _SequenceApiService(this.responses);

  final List<ApiResponse> responses;
  final List<Map<String, dynamic>> payloads = [];
  int _index = 0;

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    payloads.add(
      jsonDecode(jsonEncode(request.payload)) as Map<String, dynamic>,
    );
    final response = responses[_index.clamp(0, responses.length - 1)];
    _index++;
    return response;
  }
}

class _BlockingApiService extends ApiService {
  _BlockingApiService(this.response);

  final ApiResponse response;
  final List<Map<String, dynamic>> payloads = [];
  final Completer<void> release = Completer<void>();

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    payloads.add(
      jsonDecode(jsonEncode(request.payload)) as Map<String, dynamic>,
    );
    await release.future;
    return response;
  }
}

class _FirstRequestBlockingImageApiService extends ApiService {
  final List<Map<String, dynamic>> payloads = [];
  final Completer<void> firstRequestStarted = Completer<void>();
  final Completer<void> releaseFirstRequest = Completer<void>();

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    final payload =
        jsonDecode(jsonEncode(request.payload)) as Map<String, dynamic>;
    payloads.add(payload);
    if (payloads.length == 1) {
      firstRequestStarted.complete();
      await releaseFirstRequest.future;
    }
    final parameters = _parameters(payload);
    return _successResponseWithSize(
      (parameters['width'] as num).toInt(),
      (parameters['height'] as num).toInt(),
    );
  }
}

class _BlockingEncodeVibeUseCase extends EncodeVibeUseCase {
  final Completer<String> release = Completer<String>();
  int calls = 0;

  @override
  Future<String> call({
    required Uint8List imageBytes,
    required double informationExtracted,
    required String model,
    required String token,
    required String proxy,
    String endpoint = EncodeVibeUseCase.officialEndpoint,
  }) {
    calls++;
    return release.future;
  }
}

class _FirstVibeEncodingBlockingUseCase extends EncodeVibeUseCase {
  final Completer<void> firstRequestStarted = Completer<void>();
  final Completer<String> releaseFirst = Completer<String>();
  final List<Uint8List> requestedImages = [];

  @override
  Future<String> call({
    required Uint8List imageBytes,
    required double informationExtracted,
    required String model,
    required String token,
    required String proxy,
    String endpoint = EncodeVibeUseCase.officialEndpoint,
  }) {
    requestedImages.add(Uint8List.fromList(imageBytes));
    if (requestedImages.length == 1) {
      firstRequestStarted.complete();
      return releaseFirst.future;
    }
    return Future.value('encoding-B');
  }
}

class _NoopFileService extends FileService {
  @override
  Future<String?> savePictureToFile(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async =>
      '/tmp/$fileName';

  @override
  String generateRandomString() => 'audit';
}

class _EnhanceRecordingViewmodel extends GenerationPageViewmodel {
  I2iRequestBatch? capturedBatch;

  @override
  Command<void, InfoCardContent> createGenerationCommand({
    required int workerIndex,
    I2iRequestBatch? presetBatch,
    int? seedOverride,
    String promptSuffix = '',
  }) {
    capturedBatch = presetBatch;
    return Command.createAsyncNoParam(
      () async => InfoCardContent.fromEmpty(),
      initialValue: InfoCardContent.fromEmpty(),
    );
  }

  @override
  void addAndRunCommand(Command<void, InfoCardContent> command) {
    commandList.add(command);
  }
}

ApiResponse _successResponse() {
  final output = _solidPng(20, 40, 60);
  final archive = Archive()
    ..addFile(ArchiveFile('image_0.png', output.length, output));
  return ApiResponse(
    status: '200',
    data: Uint8List.fromList(ZipEncoder().encode(archive)!),
  );
}

ApiResponse _successResponseWithSize(int width, int height) {
  final output = _solidPngWithSize(width, height, 20, 220, 60);
  final archive = Archive()
    ..addFile(ArchiveFile('image_0.png', output.length, output));
  return ApiResponse(
    status: '200',
    data: Uint8List.fromList(ZipEncoder().encode(archive)!),
  );
}

Uint8List _solidPng(int red, int green, int blue) {
  return _solidPngWithSize(64, 64, red, green, blue);
}

Uint8List _solidPngWithSize(
  int width,
  int height,
  int red,
  int green,
  int blue,
) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _maskPng({required bool left}) {
  final image = img.Image(width: 64, height: 64, numChannels: 3);
  img.fillRect(
    image,
    x1: left ? 4 : 36,
    y1: 12,
    x2: left ? 27 : 59,
    y2: 51,
    color: img.ColorRgb8(255, 255, 255),
  );
  return Uint8List.fromList(img.encodePng(image));
}

Future<void> _runCommand(
  WidgetTester tester,
  Command<void, InfoCardContent> command,
) async {
  command();
  await tester.pumpAndSettle();
  expect(command.isExecuting.value, isFalse);
}

Map<String, dynamic> _parameters(Map<String, dynamic> payload) =>
    payload['parameters'] as Map<String, dynamic>;

I2iRequestBatch _smallSerialSplitBatch(Uint8List baseBytes) {
  final requestMask = _solidPng(255, 255, 255);
  final latentMask = _solidPngWithSize(8, 8, 255, 255, 255);
  final baseImageB64 = base64Encode(baseBytes);
  final maskB64 = base64Encode(requestMask);
  final blendMaskB64 = base64Encode(latentMask);

  I2iRequestPlan tile(int x, String label, Uint8List requestImage) =>
      I2iRequestPlan(
        imageB64: base64Encode(requestImage),
        maskB64: maskB64,
        blendMaskB64: blendMaskB64,
        width: 64,
        height: 64,
        strength: 0.7,
        noise: 0,
        addOriginalImage: false,
        composite: AutocropCompositeInfo(
          outer: CropRect(x: x, y: 0, w: 32, h: 64),
          contentOffsetX: 0,
          contentOffsetY: 0,
          contentWidth: 32,
          contentHeight: 64,
          scale: 1,
        ),
        summary: label,
      );

  return I2iRequestBatch(
    plans: [
      tile(0, 'left tile', _solidPng(220, 30, 30)),
      tile(32, 'right tile', _solidPng(30, 30, 220)),
    ],
    compositeBaseImageB64: baseImageB64,
    serial: true,
    summary: 'two serial audit tiles',
  );
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
          strs: ['audit negative prompt'],
          prompts: [],
        ),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(
          sizes: const [GenerationSize(width: 832, height: 1216)],
          randomSeed: false,
          seed: 42,
        )..model = 'nai-diffusion-4-5-full',
        settings: Settings.fromJson({
          'api_key': 'pst-audit',
          'debug_api_enabled': true,
          'debug_api_path': 'https://audit.invalid/generate-image',
          'generation_count': 0,
          'generation_interval': 0,
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

  testWidgets('unchanged failed retry preserves the same sequential prompt',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.rootPromptConfig
      ..selectionMethod = 'single_sequential'
      ..shuffled = false
      ..num = 1
      ..strs = ['prompt-A', 'prompt-B'];

    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads, hasLength(2));
    expect(api.payloads.first['input'], 'prompt-A');
    expect(api.payloads.last['input'], 'prompt-A');
    expect(
      _parameters(api.payloads.last)['seed'],
      _parameters(api.payloads.first)['seed'],
    );
    viewmodel.dispose();
  });

  testWidgets('file-name template change invalidates the full cached result',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.rootPromptConfig
      ..selectionMethod = 'single_sequential'
      ..shuffled = false
      ..num = 1
      ..strs = ['prompt-A', 'prompt-B'];

    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );
    config.settings.fileNamePrefixKey = 'changed-prefix';
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads, hasLength(2));
    expect(api.payloads.first['input'], 'prompt-A');
    expect(api.payloads.last['input'], 'prompt-B');
    viewmodel.dispose();
  });

  testWidgets('PR retry sends current B instead of cached A', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();

    config.preciseReferenceConfigList.add(
      PreciseReferenceConfig(imageB64: 'precise-A', fileName: 'A.png'),
    );
    config.setPreciseReferenceEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.preciseReferenceConfigList
      ..clear()
      ..add(
        PreciseReferenceConfig(imageB64: 'precise-B', fileName: 'B.png'),
      );
    config.setPreciseReferenceEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads, hasLength(2));
    expect(
      _parameters(api.payloads.first)['director_reference_images'],
      ['precise-A'],
    );
    expect(
      _parameters(api.payloads.last)['director_reference_images'],
      ['precise-B'],
    );
    viewmodel.dispose();
  });

  testWidgets('Vibe retry sends current B instead of cached A', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();

    config.vibeConfigListV4.add(
      VibeConfigV4(
        fileName: 'A.png',
        vibeB64: 'vibe-A',
        referenceStrength: 0.6,
      ),
    );
    config.setVibeEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.vibeConfigListV4
      ..clear()
      ..add(
        VibeConfigV4(
          fileName: 'B.png',
          vibeB64: 'vibe-B',
          referenceStrength: 0.6,
        ),
      );
    config.setVibeEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads, hasLength(2));
    expect(
      _parameters(api.payloads.first)['reference_image_multiple'],
      ['vibe-A'],
    );
    expect(
      _parameters(api.payloads.last)['reference_image_multiple'],
      ['vibe-B'],
    );
    viewmodel.dispose();
  });

  testWidgets('I2I retry sends current B instead of cached A', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();

    config.i2iConfig.setImage(_solidPng(255, 0, 0));
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.i2iConfig.setImage(_solidPng(0, 0, 255));
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads, hasLength(2));
    final firstImage = _parameters(api.payloads.first)['image'] as String;
    final secondImage = _parameters(api.payloads.last)['image'] as String;
    expect(secondImage, isNot(firstImage));
    final decoded = img.decodePng(base64Decode(secondImage))!;
    final pixel = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
    expect(pixel.b.toInt(), greaterThan(pixel.r.toInt()));
    viewmodel.dispose();
  });

  testWidgets('successful PR generation clears A before later B',
      (tester) async {
    final api = _SequenceApiService([_successResponse(), _successResponse()]);
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _NoopFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.preciseReferenceConfigList.add(
      PreciseReferenceConfig(imageB64: 'precise-A', fileName: 'A.png'),
    );
    config.setPreciseReferenceEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.preciseReferenceConfigList
      ..clear()
      ..add(
        PreciseReferenceConfig(imageB64: 'precise-B', fileName: 'B.png'),
      );
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(
      _parameters(api.payloads.last)['director_reference_images'],
      ['precise-B'],
    );
    viewmodel.dispose();
  });

  testWidgets('PR retry omits references after feature is disabled',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.preciseReferenceConfigList.add(
      PreciseReferenceConfig(imageB64: 'precise-A', fileName: 'A.png'),
    );
    config.setPreciseReferenceEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.setPreciseReferenceEnabled(false);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(
      _parameters(api.payloads.last).containsKey('director_reference_images'),
      isFalse,
    );
    viewmodel.dispose();
  });

  testWidgets('I2I retry becomes txt2img after source removal', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.i2iConfig.setImage(_solidPng(255, 0, 0));
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.i2iConfig.removeImage();
    config.clearI2iResourceState();
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads.last['action'], 'generate');
    expect(_parameters(api.payloads.last).containsKey('image'), isFalse);
    viewmodel.dispose();
  });

  testWidgets('Vibe retry removes encoding after feature is disabled',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.vibeConfigListV4.add(
      VibeConfigV4(
        fileName: 'A.png',
        vibeB64: 'vibe-A',
        referenceStrength: 0.6,
      ),
    );
    config.setVibeEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.setVibeEnabled(false);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(
      _parameters(api.payloads.last)['reference_image_multiple'],
      isEmpty,
    );
    viewmodel.dispose();
  });

  testWidgets('Director next run uses B after failed A request',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>().directorToolConfig;
    final a = _solidPng(255, 0, 0);
    final b = _solidPng(0, 0, 255);

    config.setImage(a);
    viewmodel.runDirectorTool();
    await tester.pumpAndSettle();
    config.setImage(b);
    viewmodel.runDirectorTool();
    await tester.pumpAndSettle();

    expect(api.payloads, hasLength(2));
    expect(api.payloads.first['image'], base64Encode(a));
    expect(api.payloads.last['image'], base64Encode(b));
    viewmodel.dispose();
  });

  test('Enhance preparation is cancelled when A is replaced by B', () async {
    final viewmodel = _EnhanceRecordingViewmodel();
    final enhance = GetIt.I<PayloadConfig>().enhanceConfig;
    final a = _solidPng(255, 0, 0);
    final b = _solidPng(0, 0, 255);

    enhance.setImage(a);
    final pending = viewmodel.runEnhanceGeneration();
    enhance.setImage(b);
    final started = await pending;

    expect(started, isFalse);
    expect(viewmodel.capturedBatch, isNull);
    viewmodel.dispose();
  });

  test('Director tool payload fields do not leak across all tool switches', () {
    final config = GetIt.I<PayloadConfig>().directorToolConfig;
    config.setImage(_solidPng(10, 20, 30));
    config
      ..setOverrideEnabled(true)
      ..setOverridePrompt('audit prompt')
      ..setDefry(4);

    for (final type in [
      'colorize',
      'emotion',
      'lineart',
      'sketch',
      'declutter',
      'declutter-keep-bubbles',
      'bg-removal',
    ]) {
      config.setType(type);
      final payload = config.getPayload();
      expect(payload['req_type'], type);
      if (type == 'colorize' || type == 'emotion') {
        expect(payload['prompt'], isNotNull);
        expect(payload['defry'], 4);
      } else {
        expect(payload.containsKey('prompt'), isFalse);
        expect(payload.containsKey('defry'), isFalse);
      }
    }
  });

  testWidgets('PR retry drops references after switching to a non-V4.5 model',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.preciseReferenceConfigList.add(
      PreciseReferenceConfig(imageB64: 'precise-A', fileName: 'A.png'),
    );
    config.setPreciseReferenceEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.paramConfig.model = 'nai-diffusion-4-full';
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads.last['model'], 'nai-diffusion-4-full');
    expect(
      _parameters(api.payloads.last).containsKey('director_reference_images'),
      isFalse,
    );
    viewmodel.dispose();
  });

  testWidgets('PR retry respects a card being disabled', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    final reference =
        PreciseReferenceConfig(imageB64: 'precise-A', fileName: 'A.png');
    config.preciseReferenceConfigList.add(reference);
    config.setPreciseReferenceEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    reference.enabled = false;
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(
      _parameters(api.payloads.last)['director_reference_images'] ?? const [],
      isEmpty,
    );
    viewmodel.dispose();
  });

  testWidgets('failed PR request can switch cleanly to Vibe', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.preciseReferenceConfigList.add(
      PreciseReferenceConfig(imageB64: 'precise-A', fileName: 'A.png'),
    );
    config.setPreciseReferenceEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.vibeConfigListV4.add(
      VibeConfigV4(
        fileName: 'B.png',
        vibeB64: 'vibe-B',
        referenceStrength: 0.6,
      ),
    );
    config.setVibeEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    final parameters = _parameters(api.payloads.last);
    expect(parameters['reference_image_multiple'], ['vibe-B']);
    expect(parameters['director_reference_images'] ?? const [], isEmpty);
    viewmodel.dispose();
  });

  test('Vibe encoding tolerates list replacement while extraction is pending',
      () async {
    final encoder = _BlockingEncodeVibeUseCase();
    final viewmodel = GenerationPageViewmodel(encodeVibeUseCase: encoder);
    final config = GetIt.I<PayloadConfig>();
    final a = VibeConfigV4(
      fileName: 'A.png',
      imageBytes: Uint8List.fromList([1, 2, 3]),
      referenceStrength: 0.6,
    );
    final b = VibeConfigV4(
      fileName: 'B.png',
      vibeB64: 'vibe-B',
      referenceStrength: 0.6,
    );
    config.vibeConfigListV4.add(a);
    config.setVibeEnabled(true);

    final pending = viewmodel.ensureVibeEncodings(token: 'test-token');
    await Future<void>.delayed(Duration.zero);
    config.vibeConfigListV4
      ..clear()
      ..add(b);
    encoder.release.complete('encoding-A');

    await expectLater(pending, completes);
    expect(config.vibeConfigListV4, [same(b)]);
    expect(b.encodingFor(config.paramConfig.model), 'vibe-B');
    viewmodel.dispose();
  });

  test(
      'Vibe generation finishes with B when unencoded A is replaced mid-extraction',
      () async {
    final api = _SequenceApiService([_successResponse()]);
    final encoder = _FirstVibeEncodingBlockingUseCase();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      encodeVibeUseCase: encoder,
      fileService: _NoopFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    final imageA = Uint8List.fromList([1, 2, 3]);
    final imageB = Uint8List.fromList([4, 5, 6]);
    config.vibeConfigListV4.add(
      VibeConfigV4(
        fileName: 'A.png',
        imageBytes: imageA,
        referenceStrength: 0.6,
      ),
    );
    config.setVibeEnabled(true);

    final command = viewmodel.createGenerationCommand(workerIndex: 0);
    final completion = command.executeWithFuture();
    await encoder.firstRequestStarted.future
        .timeout(const Duration(seconds: 2));
    expect(encoder.requestedImages, [imageA]);

    config.vibeConfigListV4
      ..clear()
      ..add(
        VibeConfigV4(
          fileName: 'B.png',
          imageBytes: imageB,
          referenceStrength: 0.6,
        ),
      );
    encoder.releaseFirst.complete('encoding-A');
    await completion.timeout(const Duration(seconds: 2));

    expect(encoder.requestedImages, [imageA, imageB]);
    expect(api.payloads, hasLength(1));
    expect(
      _parameters(api.payloads.single)['reference_image_multiple'],
      ['encoding-B'],
    );
    viewmodel.dispose();
  });

  testWidgets('I2I retry uses a changed mask instead of the cached mask',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.i2iConfig.setImage(_solidPng(80, 90, 100));
    config.i2iConfig.setMask(_maskPng(left: true), const []);
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.i2iConfig.setMask(_maskPng(left: false), const []);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    final first = _parameters(api.payloads.first)['mask'] as String;
    final second = _parameters(api.payloads.last)['mask'] as String;
    expect(second, isNot(first));
    viewmodel.dispose();
  });

  testWidgets('I2I retry becomes img2img after its mask is removed',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.i2iConfig.setImage(_solidPng(80, 90, 100));
    config.i2iConfig.setMask(_maskPng(left: true), const []);
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.i2iConfig.removeMask();
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads.last['action'], 'img2img');
    expect(_parameters(api.payloads.last).containsKey('mask'), isFalse);
    viewmodel.dispose();
  });

  testWidgets('I2I retry applies changed strength and noise', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.i2iConfig.setImage(_solidPng(80, 90, 100));
    config.i2iConfig
      ..setStrength(0.25)
      ..setNoise(0.1);
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.i2iConfig
      ..setStrength(0.8)
      ..setNoise(0.4);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    final parameters = _parameters(api.payloads.last);
    expect(parameters['strength'], closeTo(0.8, 0.000001));
    expect(parameters['noise'], closeTo(0.4, 0.000001));
    viewmodel.dispose();
  });

  testWidgets('I2I retry applies changed request size', (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.i2iConfig
      ..setImage(_solidPng(80, 90, 100))
      ..setRequestSize(const GenerationSize(width: 832, height: 1216));
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.i2iConfig.setRequestSize(
      const GenerationSize(width: 1024, height: 1024),
    );
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    final parameters = _parameters(api.payloads.last);
    expect(parameters['width'], 1024);
    expect(parameters['height'], 1024);
    viewmodel.dispose();
  });

  testWidgets('I2I retry applies a newly selected manual focus frame',
      (tester) async {
    final api = _RecordingFailureApiService();
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final config = GetIt.I<PayloadConfig>();
    config.i2iConfig.setImage(_solidPng(80, 90, 100));
    config.setI2iEnabled(true);
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    config.i2iConfig.setManualFocusFrame(
      const CropRect(x: 8, y: 8, w: 48, h: 48),
    );
    await _runCommand(
      tester,
      viewmodel.createGenerationCommand(workerIndex: 0),
    );

    expect(api.payloads.last['action'], 'infill');
    expect(_parameters(api.payloads.last)['mask'], isNotNull);
    viewmodel.dispose();
  });

  test('Enhance preparation is cancelled when its image is removed', () async {
    final viewmodel = _EnhanceRecordingViewmodel();
    final enhance = GetIt.I<PayloadConfig>().enhanceConfig;
    enhance.setImage(_solidPng(255, 0, 0));

    final pending = viewmodel.runEnhanceGeneration();
    enhance.removeImage();
    final started = await pending;

    expect(started, isFalse);
    expect(viewmodel.capturedBatch, isNull);
    viewmodel.dispose();
  });

  test('Enhance preparation is cancelled when scale or preset changes',
      () async {
    final viewmodel = _EnhanceRecordingViewmodel();
    final enhance = GetIt.I<PayloadConfig>().enhanceConfig;
    enhance.setImage(_solidPng(255, 0, 0));

    final pending = viewmodel.runEnhanceGeneration();
    enhance
      ..setScale(1.0)
      ..setPresetIndex(4);
    final started = await pending;

    expect(started, isFalse);
    expect(viewmodel.capturedBatch, isNull);
    viewmodel.dispose();
  });

  testWidgets(
      'Director response keeps the request snapshot while config changes',
      (tester) async {
    final api = _BlockingApiService(_successResponse());
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _NoopFileService(),
    );
    final config = GetIt.I<PayloadConfig>().directorToolConfig;
    final a = _solidPng(255, 0, 0);
    final b = _solidPng(0, 0, 255);
    config
      ..setImage(a)
      ..setType('lineart');

    viewmodel.runDirectorTool();
    for (var attempt = 0; attempt < 20 && api.payloads.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(api.payloads, hasLength(1));
    config
      ..setImage(b)
      ..setType('bg-removal');
    api.release.complete();
    await tester.pumpAndSettle();

    expect(api.payloads.single['req_type'], 'lineart');
    expect(api.payloads.single['image'], base64Encode(a));
    expect(viewmodel.lastDirectorCommand!.value.imageBytes, isNotNull);
    expect(viewmodel.lastDirectorCommand!.value.additionalInfo['req_type'],
        'lineart');
    viewmodel.dispose();
  });

  testWidgets(
      'Focus inpaint response composites onto initiating A after source becomes B',
      (tester) async {
    final api = _FirstRequestBlockingImageApiService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _NoopFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.i2iConfig.setImage(_solidPng(240, 20, 20));
    config.i2iConfig.setMask(
      _maskPng(left: true),
      const [],
      focusFrame: const CropRect(x: 0, y: 0, w: 32, h: 64),
    );
    config.setI2iEnabled(true);

    final command = viewmodel.createGenerationCommand(workerIndex: 0);
    command();
    for (var attempt = 0; attempt < 100 && api.payloads.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(api.payloads, hasLength(1), reason: command.value.info);
    config.i2iConfig.setImage(_solidPng(20, 20, 240));
    api.releaseFirstRequest.complete();
    await tester.pumpAndSettle();

    expect(command.isExecuting.value, isFalse);
    final output = img.decodePng(command.value.imageBytes!)!;
    final untouched = output.getPixel(63, 32);
    expect(untouched.r.toInt(), greaterThan(untouched.b.toInt()));
    expect(untouched.r.toInt(), greaterThan(180));
    viewmodel.dispose();
  });

  testWidgets(
      'split inpaint freezes prompt model references and seed before first await',
      (tester) async {
    final api = _FirstRequestBlockingImageApiService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _NoopFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.rootPromptConfig
      ..selectionMethod = 'single_sequential'
      ..shuffled = false
      ..num = 1
      ..strs = ['prompt-A', 'prompt-next'];
    config.preciseReferenceConfigList.add(
      PreciseReferenceConfig(imageB64: 'precise-A', fileName: 'A.png'),
    );
    config.setPreciseReferenceEnabled(true);
    final batch = _smallSerialSplitBatch(_solidPng(240, 20, 20));

    final command = viewmodel.createGenerationCommand(
      workerIndex: 0,
      presetBatch: batch,
    );
    command();
    for (var attempt = 0; attempt < 100 && api.payloads.isEmpty; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(api.payloads, hasLength(1), reason: command.value.info);

    config.rootPromptConfig.strs = ['prompt-B'];
    config.paramConfig.model = 'nai-diffusion-3';
    config.paramConfig.seed = 987654321;
    config.preciseReferenceConfigList
      ..clear()
      ..add(
        PreciseReferenceConfig(imageB64: 'precise-B', fileName: 'B.png'),
      );
    config.i2iConfig.setImage(_solidPng(20, 20, 240));
    api.releaseFirstRequest.complete();
    await tester.pumpAndSettle();

    expect(command.isExecuting.value, isFalse);
    expect(api.payloads, hasLength(2));
    final first = api.payloads.first;
    final second = api.payloads.last;
    expect(first['input'], 'prompt-A');
    expect(second['input'], first['input']);
    expect(second['model'], first['model']);
    expect(second['action'], first['action']);
    expect(_parameters(second)['seed'], _parameters(first)['seed']);
    expect(
      _parameters(second)['director_reference_images'],
      ['precise-A'],
    );
    expect(
      _parameters(second)['director_reference_images'],
      _parameters(first)['director_reference_images'],
    );
    expect(
      _parameters(second)['image'],
      isNot(_parameters(first)['image']),
    );
    viewmodel.dispose();
  });

  test('parallel PR preprocessing keeps both source color identities',
      () async {
    final results = await Future.wait([
      PreciseReferenceConfig.fromBytes(_solidPng(255, 0, 0), 'A.png'),
      PreciseReferenceConfig.fromBytes(_solidPng(0, 0, 255), 'B.png'),
    ]);

    final a = img.decodePng(results[0].imageBytes)!;
    final b = img.decodePng(results[1].imageBytes)!;
    final aPixel = a.getPixel(a.width ~/ 2, a.height ~/ 2);
    final bPixel = b.getPixel(b.width ~/ 2, b.height ~/ 2);
    expect(aPixel.r.toInt(), greaterThan(aPixel.b.toInt()));
    expect(bPixel.b.toInt(), greaterThan(bPixel.r.toInt()));
  });

  test('100 cross-feature payload builds never leak inactive image fields', () {
    final config = GetIt.I<PayloadConfig>();
    for (var index = 0; index < 100; index++) {
      config.resetTransientConfigs();
      config.preciseReferenceConfigList.add(
        PreciseReferenceConfig(
          imageB64: 'precise-$index',
          fileName: 'precise-$index.png',
        ),
      );
      config.setPreciseReferenceEnabled(true);
      final precise = GeneratePayloadUseCase(payloadConfig: config)().payload;
      final preciseParams = _parameters(precise);
      expect(preciseParams['director_reference_images'], ['precise-$index']);
      expect(preciseParams['reference_image_multiple'] ?? const [], isEmpty);
      expect(preciseParams.containsKey('image'), isFalse);

      config.vibeConfigListV4.add(
        VibeConfigV4(
          fileName: 'vibe-$index.png',
          vibeB64: 'vibe-$index',
          referenceStrength: 0.5,
        ),
      );
      config.setVibeEnabled(true);
      final vibe = GeneratePayloadUseCase(payloadConfig: config)().payload;
      final vibeParams = _parameters(vibe);
      expect(vibeParams['reference_image_multiple'], ['vibe-$index']);
      expect(vibeParams['director_reference_images'] ?? const [], isEmpty);
      expect(vibeParams.containsKey('image'), isFalse);
    }
  });
}
