import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/use_cases/encode_vibe_use_case.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class _FakeEncodeVibeUseCase extends EncodeVibeUseCase {
  int calls = 0;
  int failuresRemaining = 0;
  Completer<String>? blocker;
  final List<double> informationValues = [];
  final List<String> models = [];

  @override
  Future<String> call({
    required Uint8List imageBytes,
    required double informationExtracted,
    required String model,
    required String token,
    required String proxy,
    String endpoint = EncodeVibeUseCase.officialEndpoint,
  }) async {
    calls++;
    informationValues.add(informationExtracted);
    models.add(model);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const VibeEncodingException('simulated encode failure');
    }
    final pending = blocker;
    if (pending != null) return pending.future;
    return 'encoding-$calls';
  }
}

class _FakeApiService extends ApiService {
  final ApiResponse response;
  int calls = 0;
  final List<ApiRequest> requests = [];

  _FakeApiService(this.response);

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    calls++;
    requests.add(request);
    return response;
  }
}

class _FakeAccountService extends AccountService {
  _FakeAccountService({
    List<SubscriptionInfo?> responses = const [],
    this.blocker,
  }) : responses = List.of(responses);

  final List<SubscriptionInfo?> responses;
  final Completer<SubscriptionInfo?>? blocker;
  int calls = 0;

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    calls++;
    if (responses.isNotEmpty) return responses.removeAt(0);
    final pending = blocker;
    if (pending != null) return pending.future;
    return null;
  }
}

class _RecordingFileService extends FileService {
  final List<String> savedNames = [];

  @override
  Future<String?> savePictureToFile(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async {
    savedNames.add(fileName);
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

Future<void> waitForCurrentCommand(
  WidgetTester tester,
  GenerationPageViewmodel viewmodel,
) async {
  await tester.pump(const Duration(milliseconds: 1));
  final command = viewmodel.currentCommand;
  if (command == null || !command.isExecuting.value) {
    await tester.pump();
    return;
  }
  final completer = Completer<void>();
  void listener() {
    if (!command.isExecuting.value && !completer.isCompleted) {
      completer.complete();
    }
  }

  command.isExecuting.addListener(listener);
  await tester.runAsync(
    () => completer.future.timeout(const Duration(seconds: 10)),
  );
  command.isExecuting.removeListener(listener);
  await tester.pump();
}

class _SchedulingViewmodel extends GenerationPageViewmodel {
  int nextCommandCalls = 0;

  @override
  void nextCommand() {
    nextCommandCalls++;
  }
}

class _WorkerRecordingViewmodel extends GenerationPageViewmodel {
  final List<int> createdWorkers = [];
  I2iRequestBatch? lastPresetBatch;
  int? lastSeedOverride;
  String? lastPromptSuffix;

  @override
  Command<void, InfoCardContent> createGenerationCommand({
    required int workerIndex,
    I2iRequestBatch? presetBatch,
    int? seedOverride,
    String promptSuffix = '',
  }) {
    createdWorkers.add(workerIndex);
    lastPresetBatch = presetBatch;
    lastSeedOverride = seedOverride;
    lastPromptSuffix = promptSuffix;
    return Command.createAsyncNoParam(
      () async => InfoCardContent(
        title: 'worker-$workerIndex',
        info: '',
        additionalInfo: const {},
      ),
      initialValue: InfoCardContent.fromEmpty(),
    );
  }

  /// Records the command without executing it, so tests stay free of the
  /// zero-duration notification timers flutter_command schedules.
  @override
  void addAndRunCommand(Command<void, InfoCardContent> command) {
    commandList.add(command);
    notifyListeners();
  }
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

  test('Enhance prepares once in background and forwards website overrides',
      () async {
    final viewmodel = _WorkerRecordingViewmodel();
    final config = GetIt.I<PayloadConfig>();
    final originalPrompt = List<String>.of(config.rootPromptConfig.strs);
    final originalSeed = config.paramConfig.seed;
    final sourceImage = img.Image(width: 64, height: 64, numChannels: 3);
    img.fill(sourceImage, color: img.ColorRgb8(60, 90, 150));
    config.enhanceConfig.setImage(
      Uint8List.fromList(img.encodePng(sourceImage)),
    );

    final firstRun = viewmodel.runEnhanceGeneration();
    expect(viewmodel.isPreparingEnhance, isTrue);
    expect(await viewmodel.runEnhanceGeneration(), isFalse);
    expect(await firstRun, isTrue);

    expect(viewmodel.isPreparingEnhance, isFalse);
    expect(viewmodel.createdWorkers, [0]);
    expect(viewmodel.lastSeedOverride, inInclusiveRange(0, 0xFFFFFFFF));
    expect(viewmodel.lastPromptSuffix, '-2::upscaled, blurry::,');
    expect(viewmodel.lastPresetBatch?.plans, hasLength(1));
    final plan = viewmodel.lastPresetBatch!.plans.single;
    expect(plan.strength, config.enhanceConfig.strength);
    expect(plan.noise, config.enhanceConfig.noise);
    expect(config.rootPromptConfig.strs, originalPrompt);
    expect(config.paramConfig.seed, originalSeed);
  });

  testWidgets('Remove Background adds Masked, Generated and Blend results', (
    tester,
  ) async {
    Uint8List coloredPng(int red, int green, int blue) {
      final image = img.Image(width: 32, height: 32, numChannels: 3);
      img.fill(image, color: img.ColorRgb8(red, green, blue));
      return Uint8List.fromList(img.encodePng(image));
    }

    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        coloredPng(220, 0, 0),
        coloredPng(0, 220, 0),
        coloredPng(0, 0, 220),
      ]),
    ));
    final files = _RecordingFileService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
    );
    final payload = GetIt.I<PayloadConfig>();
    payload.settings.debugApiEnabled = true;
    payload.directorToolConfig.setImage(coloredPng(80, 80, 80));

    viewmodel.runDirectorTool();
    await tester.pumpAndSettle();

    expect(api.calls, 1);
    expect(viewmodel.commandList, hasLength(3));
    expect(files.savedNames, hasLength(3));
    final results = viewmodel.commandList
        .map((command) => command.value)
        .toList(growable: false);
    expect(
      results
          .map((result) => result.additionalInfo['background_removal_variant']),
      ['Masked', 'Generated', 'Blend'],
    );
    expect(results.map((result) => result.imageBytes), everyElement(isNotNull));
    expect(results[0].anlasCost, 6);
    expect(results[0].anlasCostIsEstimated, isTrue);
    expect(results[1].title, contains('generated'));
    expect(results[2].title, contains('blend'));
  });

  testWidgets('Director Tools reports HTTP JSON errors before ZIP decoding', (
    tester,
  ) async {
    final api = _FakeApiService(ApiResponse(
      status: '500',
      data: Uint8List.fromList(utf8.encode(
        '{"statusCode":500,"message":"upstream i/o timeout"}',
      )),
    ));
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final payload = GetIt.I<PayloadConfig>();
    payload.settings.debugApiEnabled = true;
    final source = img.Image(width: 32, height: 32, numChannels: 3);
    payload.directorToolConfig.setImage(
      Uint8List.fromList(img.encodePng(source)),
    );

    viewmodel.runDirectorTool();
    await tester.pumpAndSettle();

    final error = viewmodel.commandList.single.value.info;
    expect(error, contains('NovelAI server timed out'));
    expect(error, contains('HTTP 500'));
    expect(error, isNot(contains('End of Central Directory')));
    viewmodel.dispose();
  });

  testWidgets(
      'generation completes without waiting for a stalled balance refresh and shows cost',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final balanceBlocker = Completer<SubscriptionInfo?>();
    final accounts = _FakeAccountService(blocker: balanceBlocker);
    final files = _RecordingFileService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: files,
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..apiKey = 'pst-test'
      ..debugApiEnabled = false
      ..generationCount = 1
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    await waitForCurrentCommand(tester, viewmodel);

    expect(files.savedNames, hasLength(1));
    expect(viewmodel.currentCommand!.isExecuting.value, isFalse);
    expect(viewmodel.currentCommand!.value.anlasCost, isNotNull);
    expect(viewmodel.currentCommand!.value.anlasCostIsEstimated, isTrue);
    expect(viewmodel.commandStatus.isGenerationActive.value, isFalse);
    expect(accounts.calls, greaterThanOrEqualTo(1));

    balanceBlocker.complete(null);
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets('single-image batch reconciles exact cost in the background', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final accounts = _FakeAccountService(responses: const [
      SubscriptionInfo(anlas: 100, tier: 1, active: true),
      SubscriptionInfo(anlas: 100, tier: 1, active: true),
      SubscriptionInfo(anlas: 80, tier: 1, active: true),
    ]);
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: _RecordingFileService(),
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..apiKey = 'pst-test'
      ..debugApiEnabled = false
      ..generationCount = 1
      ..generationIntervalSec = 0;
    await viewmodel.refreshSubscriptionSnapshot();

    viewmodel.startGeneration();
    await waitForCurrentCommand(tester, viewmodel);
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (viewmodel.currentCommand!.value.anlasRemaining == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    final content = viewmodel.currentCommand!.value;
    expect(content.anlasCost, 20);
    expect(content.anlasCostIsEstimated, isFalse);
    expect(content.anlasRemaining, 80);
    expect(content.batchAnlasCost, isNull);
    expect(accounts.calls, 3);
    viewmodel.dispose();
  });

  testWidgets(
      'multi-image batch keeps per-image estimates and reports one exact total',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final accounts = _FakeAccountService(responses: const [
      SubscriptionInfo(anlas: 100, tier: 1, active: true),
      SubscriptionInfo(anlas: 100, tier: 1, active: true),
      SubscriptionInfo(anlas: 60, tier: 1, active: true),
    ]);
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: _RecordingFileService(),
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..apiKey = 'pst-test'
      ..debugApiEnabled = false
      ..generationCount = 2
      ..generationIntervalSec = 0;
    await viewmodel.refreshSubscriptionSnapshot();

    viewmodel.startGeneration();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((viewmodel.commandList.length < 2 ||
              viewmodel.commandList.last.value.batchAnlasCost == null) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(viewmodel.commandList, hasLength(2));
    final first = viewmodel.commandList.first.value;
    final last = viewmodel.commandList.last.value;
    expect(first.anlasCost, isNotNull);
    expect(first.anlasCostIsEstimated, isTrue);
    expect(first.batchAnlasCost, isNull);
    expect(last.anlasCost, isNotNull);
    expect(last.anlasCostIsEstimated, isTrue);
    expect(last.batchAnlasCost, 40);
    expect(last.anlasRemaining, 60);
    expect(accounts.calls, 3);
    viewmodel.dispose();
  });

  testWidgets('temporary server failures back off and pause after three', (
    tester,
  ) async {
    final api = _FakeApiService(ApiResponse(
      status: '500',
      data: Uint8List.fromList(utf8.encode(
        '{"statusCode":500,"message":"upstream i/o timeout"}',
      )),
    ));
    final viewmodel = GenerationPageViewmodel(apiService: api);
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    await tester.pump();
    await waitForCurrentCommand(tester, viewmodel);

    expect(api.calls, 1);
    expect(viewmodel.commandStatus.isWaitingForNextGeneration.value, isTrue);
    await tester.pump(const Duration(seconds: 4));
    expect(api.calls, 1);
    await tester.pump(const Duration(seconds: 1));
    await waitForCurrentCommand(tester, viewmodel);
    expect(api.calls, 2);

    await tester.pump(const Duration(seconds: 14));
    expect(api.calls, 2);
    await tester.pump(const Duration(seconds: 1));
    await waitForCurrentCommand(tester, viewmodel);
    expect(api.calls, 3);
    expect(viewmodel.commandStatus.isGenerationActive.value, isFalse);
    expect(
      viewmodel.commandList.last.value.info,
      contains('pause after three temporary server failures'),
    );
    viewmodel.dispose();
  });

  testWidgets('homepage generation applies the enabled I2I-area random seed', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    img.fill(outputImage, color: img.ColorRgb8(20, 40, 60));
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final files = _RecordingFileService();
    final accounts = _FakeAccountService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: files,
      i2iSeedRandom: Random(12345),
    );
    final config = GetIt.I<PayloadConfig>();
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 1;
    config.paramConfig
      ..randomSeed = false
      ..seed = 424242;
    config.i2iConfig
      ..setImage(Uint8List.fromList(img.encodePng(outputImage)))
      ..setRequestSize(
        const GenerationSize(width: 64, height: 64),
        mode: I2iSizeMode.manual,
      )
      ..setUseRandomSeed(true);
    config.noteI2iImported(replacing: false);

    await tester.runAsync(() async {
      viewmodel.startGeneration();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((viewmodel.currentCommand?.isExecuting.value ?? true) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    final expectedRandom = Random(12345);
    final expectedSeed = (expectedRandom.nextInt(1 << 16) << 16) |
        expectedRandom.nextInt(1 << 16);
    final request = api.requests.single.payload;
    final parameters = request['parameters'] as Map<String, dynamic>;
    expect(request['action'], 'img2img');
    expect(parameters['seed'], expectedSeed);
    expect(parameters['extra_noise_seed'], (expectedSeed - 1) & 0xFFFFFFFF);
    expect(config.paramConfig.randomSeed, isFalse);
    expect(config.paramConfig.seed, 424242);
    expect(accounts.calls, 0);
    expect(
      files.savedNames,
      hasLength(1),
      reason: viewmodel.commandList.last.value.info,
    );
    viewmodel.stopGeneration();
    await tester.pumpAndSettle();
    viewmodel.dispose();
  });

  test('Vibe encoding is cached by model and Information Extracted', () async {
    final fake = _FakeEncodeVibeUseCase();
    final viewmodel = GenerationPageViewmodel(encodeVibeUseCase: fake);
    final config = GetIt.I<PayloadConfig>();
    final vibe = VibeConfigV4(
      fileName: 'reference.png',
      imageBytes: Uint8List.fromList([1, 2, 3]),
      referenceStrength: 0.6,
      informationExtracted: 0.7,
    );
    config.vibeConfigListV4.add(vibe);
    config.setVibeEnabled(true);

    await viewmodel.ensureVibeEncodings(token: 'test-token');
    await viewmodel.ensureVibeEncodings(token: 'test-token');
    expect(fake.calls, 1);
    expect(vibe.encodingFor(config.paramConfig.model), 'encoding-1');

    vibe.informationExtracted = 0.8;
    await viewmodel.ensureVibeEncodings(token: 'test-token');
    expect(fake.calls, 2);
    expect(fake.informationValues, [0.7, 0.8]);

    config.paramConfig.model = 'nai-diffusion-4-full';
    await viewmodel.ensureVibeEncodings(token: 'test-token');
    expect(fake.calls, 3);
    expect(fake.models.last, 'nai-diffusion-4-full');

    config.paramConfig.model = 'nai-diffusion-4-5-full';
    vibe.informationExtracted = 0.7;
    await viewmodel.ensureVibeEncodings(token: 'test-token');
    expect(fake.calls, 3);
    expect(vibe.encodingFor(config.paramConfig.model), 'encoding-1');
  });

  test('Precise Reference state prevents unused Vibe extraction on V4.5',
      () async {
    final fake = _FakeEncodeVibeUseCase();
    final viewmodel = GenerationPageViewmodel(encodeVibeUseCase: fake);
    final config = GetIt.I<PayloadConfig>();
    config.vibeConfigListV4.add(
      VibeConfigV4(
        fileName: 'reference.png',
        imageBytes: Uint8List.fromList([1]),
        referenceStrength: 0.6,
      ),
    );
    config.setVibeEnabled(true);
    // Simulate stale/migrated state that bypassed the mutually exclusive
    // setters. Precise Reference wins in the V4.5 payload.
    config.preciseReferenceEnabled = true;

    await viewmodel.ensureVibeEncodings(token: 'test-token');

    expect(fake.calls, 0);
  });

  test('concurrent workers share one in-flight Vibe extraction', () async {
    final fake = _FakeEncodeVibeUseCase()..blocker = Completer<String>();
    final viewmodel = GenerationPageViewmodel(encodeVibeUseCase: fake);
    final config = GetIt.I<PayloadConfig>();
    final vibe = VibeConfigV4(
      fileName: 'reference.png',
      imageBytes: Uint8List.fromList([1]),
      referenceStrength: 0.6,
    );
    config.vibeConfigListV4.add(vibe);
    config.setVibeEnabled(true);

    final first = viewmodel.ensureVibeEncodings(token: 'test-token');
    await Future<void>.delayed(Duration.zero);
    final second = viewmodel.ensureVibeEncodings(token: 'test-token');
    await Future<void>.delayed(Duration.zero);

    expect(fake.calls, 1);
    fake.blocker!.complete('shared-encoding');
    await Future.wait([first, second]);
    expect(vibe.encodingFor(config.paramConfig.model), 'shared-encoding');
  });

  test('failed Vibe extraction is cleared so a later attempt can retry',
      () async {
    final fake = _FakeEncodeVibeUseCase()..failuresRemaining = 1;
    final viewmodel = GenerationPageViewmodel(encodeVibeUseCase: fake);
    final config = GetIt.I<PayloadConfig>();
    final vibe = VibeConfigV4(
      fileName: 'reference.png',
      imageBytes: Uint8List.fromList([1]),
      referenceStrength: 0.6,
    );
    config.vibeConfigListV4.add(vibe);
    config.setVibeEnabled(true);

    await expectLater(
      viewmodel.ensureVibeEncodings(token: 'test-token'),
      throwsA(isA<VibeEncodingException>()),
    );
    expect(vibe.encodingFor(config.paramConfig.model), isNull);

    await viewmodel.ensureVibeEncodings(token: 'test-token');
    expect(fake.calls, 2);
    expect(vibe.encodingFor(config.paramConfig.model), 'encoding-2');
  });

  test('encoded-only Vibe explains when the current model is unsupported',
      () async {
    final fake = _FakeEncodeVibeUseCase();
    final viewmodel = GenerationPageViewmodel(encodeVibeUseCase: fake);
    final config = GetIt.I<PayloadConfig>();
    final vibe = VibeConfigV4(
      fileName: 'encoded-only.naiv4vibe',
      referenceStrength: 0.6,
    );
    vibe.cacheEncoding(
      model: 'nai-diffusion-4-5-full',
      informationExtracted: 0.7,
      encoding: 'v45-only',
    );
    config.vibeConfigListV4.add(vibe);
    config.paramConfig.model = 'nai-diffusion-4-full';
    config.setVibeEnabled(true);

    await expectLater(
      viewmodel.ensureVibeEncodings(token: 'test-token'),
      throwsA(
        isA<VibeEncodingException>().having(
          (error) => error.message,
          'message',
          allOf(contains('encoded-only.naiv4vibe'),
              contains('no original image')),
        ),
      ),
    );
    expect(fake.calls, 0);
  });

  test('adding a prompt command refreshes the generation page immediately', () {
    final viewmodel = GenerationPageViewmodel();
    var notificationCount = 0;
    viewmodel.addListener(() => notificationCount++);

    final command = Command.createSyncNoParam(
      () => const InfoCardContent(
        title: 'prompt',
        info: 'generated prompt',
        additionalInfo: {},
      ),
      initialValue: InfoCardContent.fromEmpty(),
    );

    viewmodel.addAndRunCommand(command);

    expect(viewmodel.commandList, contains(command));
    expect(notificationCount, 1);
    expect(command.value.title, 'prompt');
  });

  test('generation settings update the existing config fields', () {
    final viewmodel = GenerationPageViewmodel();
    final payloadConfig = GetIt.I<PayloadConfig>();

    viewmodel.setRandomSeedEnabled(false);
    viewmodel.setSeed('123456');
    viewmodel.setGenerationInterval('12');
    viewmodel.setGenerationCount('20');

    expect(payloadConfig.paramConfig.randomSeed, isFalse);
    expect(payloadConfig.paramConfig.seed, 123456);
    expect(payloadConfig.settings.generationIntervalSec, 12);
    expect(payloadConfig.settings.generationCount, 20);
  });

  test('invalid numeric settings leave the previous values unchanged', () {
    final viewmodel = GenerationPageViewmodel();
    final payloadConfig = GetIt.I<PayloadConfig>();

    viewmodel.setSeed('not-a-number');
    viewmodel.setGenerationInterval('invalid');
    viewmodel.setGenerationCount('invalid');
    viewmodel.setGenerationInterval('-1');
    viewmodel.setGenerationCount('-1');

    expect(payloadConfig.paramConfig.seed, 42);
    expect(payloadConfig.settings.generationIntervalSec, 10);
    expect(payloadConfig.settings.generationCount, 0);
  });

  test('empty fixed seed becomes zero when generation starts', () {
    final viewmodel = _SchedulingViewmodel();
    final payloadConfig = GetIt.I<PayloadConfig>();

    viewmodel.setRandomSeedEnabled(false);
    viewmodel.setSeed('');

    expect(payloadConfig.paramConfig.seed, isNull);

    viewmodel.startGeneration();

    expect(payloadConfig.paramConfig.seed, 0);
    expect(viewmodel.nextCommandCalls, 1);
    viewmodel.stopGeneration();
  });

  test('digest hides reference image payload fields', () {
    final viewmodel = GenerationPageViewmodel();

    final digest = viewmodel.digestPayloadResult(PayloadGenerationResult(
      comment: '',
      suggestedFileName: '',
      payload: {
        'input': 'prompt',
        'model': 'nai-diffusion-4-5-full',
        'action': 'generate',
        'parameters': {
          'width': 832,
          'reference_image_multiple': ['vibe-image'],
          'director_reference_images': ['precise-image'],
          'director_reference_descriptions': ['precise-description'],
          'director_reference_information_extracted': [1.0],
          'director_reference_strength_values': [1.0],
          'director_reference_secondary_strength_values': [0.0],
        },
      },
    ));

    expect(digest['width'], 832);
    expect(digest.containsKey('reference_image_multiple'), isFalse);
    expect(digest.containsKey('director_reference_images'), isFalse);
    expect(digest.containsKey('director_reference_descriptions'), isFalse);
    expect(
      digest.containsKey('director_reference_information_extracted'),
      isFalse,
    );
    expect(digest.containsKey('director_reference_strength_values'), isFalse);
    expect(
      digest.containsKey('director_reference_secondary_strength_values'),
      isFalse,
    );
  });

  test('size selection stays non-empty and rounds manual sizes to 64', () {
    final viewmodel = GenerationPageViewmodel();
    final paramConfig = GetIt.I<PayloadConfig>().paramConfig;
    const initialSize = GenerationSize(width: 832, height: 1216);

    viewmodel.removeSize(initialSize);
    expect(paramConfig.sizes, [initialSize]);

    viewmodel.addManualSize('833', '1217');
    expect(
      paramConfig.sizes,
      contains(const GenerationSize(width: 896, height: 1280)),
    );

    viewmodel.addManualSize('invalid', '1024');
    expect(paramConfig.sizes, hasLength(2));

    viewmodel.addSize(initialSize);
    expect(paramConfig.sizes, hasLength(2));
  });

  testWidgets('generation waits for the configured interval between images', (
    tester,
  ) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    GetIt.I<PayloadConfig>().settings.generationIntervalSec = 1;
    commandStatus.isGenerationActive.value = true;

    viewmodel.scheduleNextGeneration();

    expect(commandStatus.isWaitingForNextGeneration.value, isTrue);
    await tester.pump(const Duration(milliseconds: 999));
    expect(viewmodel.nextCommandCalls, 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(viewmodel.nextCommandCalls, 1);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);
    viewmodel.dispose();
  });

  test('zero interval starts the next image immediately', () {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    GetIt.I<PayloadConfig>().settings.generationIntervalSec = 0;
    commandStatus.isGenerationActive.value = true;

    viewmodel.scheduleNextGeneration();

    expect(viewmodel.nextCommandCalls, 1);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);
    viewmodel.dispose();
  });

  testWidgets('stopping generation cancels the pending interval', (
    tester,
  ) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    GetIt.I<PayloadConfig>().settings.generationIntervalSec = 1;
    commandStatus.isGenerationActive.value = true;

    viewmodel.scheduleNextGeneration();
    viewmodel.stopGeneration();
    await tester.pump(const Duration(seconds: 1));

    expect(viewmodel.nextCommandCalls, 0);
    expect(commandStatus.isGenerationActive.value, isFalse);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);
    viewmodel.dispose();
  });

  testWidgets('finite generation stops and unlimited generation continues', (
    tester,
  ) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.generationIntervalSec = 1;
    settings.generationCount = 2;
    commandStatus.currentGenerationCount = 2;
    commandStatus.isGenerationActive.value = true;

    viewmodel.continueAfterGenerationAttempt();

    expect(commandStatus.isGenerationActive.value, isFalse);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);

    settings.generationCount = 0;
    commandStatus.currentGenerationCount = 0;
    commandStatus.isGenerationActive.value = true;
    viewmodel.continueAfterGenerationAttempt();

    expect(commandStatus.isWaitingForNextGeneration.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(viewmodel.nextCommandCalls, 1);
    viewmodel.dispose();
  });

  testWidgets('multiple enabled tokens start one parallel worker each', (
    tester,
  ) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'A', token: 'pst-a'),
      ApiTokenConfig(label: 'B', token: 'pst-b'),
      ApiTokenConfig(label: 'C', token: 'pst-c'),
    ]);

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0, 1, 2]);
    expect(viewmodel.commandList, hasLength(3));
    viewmodel.stopGeneration();
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets('disabled tokens do not get workers', (tester) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'A', token: 'pst-a'),
      ApiTokenConfig(label: 'B', token: 'pst-b', enabled: false),
      ApiTokenConfig(label: 'C', token: 'pst-c'),
    ]);

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0, 1]);
    viewmodel.stopGeneration();
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets('worker count never exceeds the requested generation count', (
    tester,
  ) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.generationCount = 2;
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'A', token: 'pst-a'),
      ApiTokenConfig(label: 'B', token: 'pst-b'),
      ApiTokenConfig(label: 'C', token: 'pst-c'),
    ]);

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0, 1]);
    viewmodel.stopGeneration();
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets('legacy single API key keeps the single-worker behaviour', (
    tester,
  ) async {
    final viewmodel = _WorkerRecordingViewmodel();

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0]);
    viewmodel.stopGeneration();
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets(
      'runSingleGeneration issues one worker-0 command outside the loop',
      (tester) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();

    viewmodel.runSingleGeneration();

    expect(viewmodel.createdWorkers, [0]);
    expect(commandStatus.isGenerationActive.value, isFalse);
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets('a failed attempt still waits before retrying', (tester) async {
    final viewmodel = _SchedulingViewmodel();
    final commandStatus = GetIt.I<CommandStatus>();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.generationIntervalSec = 1;
    settings.generationCount = 2;
    commandStatus.currentGenerationCount = 1;
    commandStatus.isGenerationActive.value = true;

    // Failed attempts do not increment currentGenerationCount, but they still
    // pass through the same post-attempt interval before a retry.
    viewmodel.continueAfterGenerationAttempt();

    expect(commandStatus.isWaitingForNextGeneration.value, isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(viewmodel.nextCommandCalls, 1);
    viewmodel.dispose();
  });
}
