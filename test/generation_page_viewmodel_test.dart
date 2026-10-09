import 'package:nai_casrand/data/models/prompt_token_snapshot.dart';
import 'package:nai_casrand/ui/generation_page/widgets/prompt_token_usage.dart';
import 'package:nai_casrand/data/models/batch_tool_snapshot.dart';
import 'package:nai_casrand/data/use_cases/enhance_request_options.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/api_token_config.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/generation_performance_diagnostics.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/vibe_config.dart';
import 'package:nai_casrand/data/models/vibe_config_v4.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/data/use_cases/encode_vibe_use_case.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';
import 'package:nai_casrand/data/use_cases/prepare_director_tool_request_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_scheduler.dart';
import 'package:nai_casrand/ui/generation_page/widgets/classic_info_card.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';

import 'i2i_pixel_goldens.dart';

Future<void> _skipPreparationFeedbackBarrier() async {}

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
    bool Function()? shouldSend,
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

class _FakePrepareDirectorToolRequestUseCase
    extends PrepareDirectorToolRequestUseCase {
  const _FakePrepareDirectorToolRequestUseCase(this.result);

  final PreparedDirectorToolImage result;

  @override
  Future<PreparedDirectorToolImage> call({
    required Uint8List imageBytes,
    required int width,
    required int height,
  }) async =>
      result;
}

class _PassthroughPrepareDirectorToolRequestUseCase
    extends PrepareDirectorToolRequestUseCase {
  const _PassthroughPrepareDirectorToolRequestUseCase();

  @override
  Future<PreparedDirectorToolImage> call({
    required Uint8List imageBytes,
    required int width,
    required int height,
  }) async {
    return PreparedDirectorToolImage(
      imageB64: base64Encode(imageBytes),
      width: width,
      height: height,
    );
  }
}

class _FailingPrepareDirectorToolRequestUseCase
    extends PrepareDirectorToolRequestUseCase {
  const _FailingPrepareDirectorToolRequestUseCase();

  @override
  Future<PreparedDirectorToolImage> call({
    required Uint8List imageBytes,
    required int width,
    required int height,
  }) {
    throw const FormatException('invalid Director source');
  }
}

class _FakeApiService extends ApiService {
  final ApiResponse response;
  int calls = 0;
  final List<ApiRequest> requests = [];

  _FakeApiService(
    this.response, {
    super.diagnosticObserver,
  });

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    calls++;
    requests.add(request);
    return response;
  }
}

class _SequenceApiService extends ApiService {
  _SequenceApiService(Iterable<ApiResponse> responses)
      : responses = List.of(responses);

  final List<ApiResponse> responses;
  final List<ApiRequest> requests = [];

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}

class _BlockingApiService extends ApiService {
  final Completer<ApiResponse> response = Completer<ApiResponse>();
  int calls = 0;

  @override
  Future<ApiResponse> fetchData(ApiRequest request) {
    calls++;
    return response.future;
  }
}

class _WaitingFanoutApiService extends ApiService {
  _WaitingFanoutApiService(this.expectedCalls, this.response);

  final int expectedCalls;
  final ApiResponse response;
  final List<ApiRequest> requests = [];
  final Completer<void> allStarted = Completer<void>();

  @override
  Future<ApiResponse> fetchData(ApiRequest request) async {
    requests.add(request);
    if (requests.length == expectedCalls && !allStarted.isCompleted) {
      allStarted.complete();
    }
    await allStarted.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError('fan-out requests did not all start'),
    );
    return response;
  }
}

class _FirstSuccessThenBlockingApiService extends ApiService {
  _FirstSuccessThenBlockingApiService(this.successData);

  final Uint8List successData;
  final Completer<ApiResponse> blockedResponse = Completer<ApiResponse>();
  final Map<String, int> callsByAuthorization = {};
  int calls = 0;

  @override
  Future<ApiResponse> fetchData(ApiRequest request) {
    calls++;
    final authorization = request.headers['authorization'] ?? '';
    final accountCalls = (callsByAuthorization[authorization] ?? 0) + 1;
    callsByAuthorization[authorization] = accountCalls;
    if (accountCalls == 1) {
      return Future.value(ApiResponse(status: '200', data: successData));
    }
    return blockedResponse.future;
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

class _ChangingOpusAccountService extends AccountService {
  int calls = 0;

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    calls++;
    return SubscriptionInfo(
      anlas: 100 - calls,
      tier: 3,
      active: true,
      usage: OpusUsage(
        percent: 80 - calls.toDouble(),
        isNegative: false,
        secondsPerPercent: 6048,
        observedAt: DateTime(2026, 8, 21).add(Duration(seconds: calls)),
      ),
    );
  }
}

class _PerTokenAccountService extends AccountService {
  _PerTokenAccountService(this.snapshots);

  final Map<String, SubscriptionInfo> snapshots;
  final Map<String, int> calls = {};
  final Completer<SubscriptionInfo?> laterCalls = Completer();

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    final call = (calls[token] ?? 0) + 1;
    calls[token] = call;
    if (call == 1) return snapshots[token];
    return laterCalls.future;
  }
}

class _TokenSequenceAccountService extends AccountService {
  _TokenSequenceAccountService(Map<String, List<SubscriptionInfo?>> responses)
      : responses = {
          for (final entry in responses.entries)
            entry.key: List.of(entry.value),
        };

  final Map<String, List<SubscriptionInfo?>> responses;

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    return responses[token]!.removeAt(0);
  }
}

class _FixedPerTokenAccountService extends AccountService {
  _FixedPerTokenAccountService(this.snapshots);

  final Map<String, SubscriptionInfo> snapshots;
  final Map<String, int> calls = {};

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    final count = (calls[token] ?? 0) + 1;
    calls[token] = count;
    final snapshot = snapshots[token];
    if (snapshot == null || count == 1 || snapshot.anlas == 0) {
      return snapshot;
    }
    return SubscriptionInfo(
      anlas: max(0, snapshot.anlas! - 30 * (count - 1)),
      tier: snapshot.tier,
      active: snapshot.active,
      usage: snapshot.usage,
      expiresAt: snapshot.expiresAt,
    );
  }
}

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

class _FailOnceFileService extends _RecordingFileService {
  bool _shouldFail = true;

  @override
  Future<String?> savePictureToFile(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async {
    savedNames.add(fileName);
    if (_shouldFail) {
      _shouldFail = false;
      throw StateError('simulated storage failure');
    }
    return '/test/$fileName';
  }
}

class _RecordingGeneratedImageStorage implements GeneratedImageStorage {
  final GeneratedImageStorage delegate;
  final List<GeneratedImageStorageRequest> requests = [];
  final List<GeneratedImageStorageSubmission> submissions = [];

  _RecordingGeneratedImageStorage(this.delegate);

  @override
  GeneratedImageStorageSubmission submit(GeneratedImageStorageRequest request) {
    requests.add(request);
    final submission = delegate.submit(request);
    submissions.add(submission);
    return submission;
  }
}

class _DelayedGeneratedImageStorage implements GeneratedImageStorage {
  final Completer<GeneratedImageFile?> publication = Completer();
  GeneratedImageStorageSubmission? submission;

  @override
  GeneratedImageStorageSubmission submit(GeneratedImageStorageRequest request) {
    return submission = GeneratedImageStorageSubmission.start(
      previewBytes: request.pngBytes,
      publish: () => publication.future,
    );
  }
}

class _QueuedDelayedGeneratedImageStorage implements GeneratedImageStorage {
  final List<Completer<GeneratedImageFile?>> publications = [];
  final List<GeneratedImageStorageSubmission> submissions = [];

  @override
  GeneratedImageStorageSubmission submit(GeneratedImageStorageRequest request) {
    final publication = Completer<GeneratedImageFile?>();
    publications.add(publication);
    final submission = GeneratedImageStorageSubmission.start(
      previewBytes: request.pngBytes,
      publish: () => publication.future,
    );
    submissions.add(submission);
    return submission;
  }
}

Uint8List directorResponseZip(List<Uint8List> images) {
  final archive = Archive();
  for (final (index, bytes) in images.indexed) {
    archive.addFile(ArchiveFile('image_$index.png', bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Uint8List indexedResponseZip(Map<int, Uint8List> images) {
  final archive = Archive();
  for (final entry in images.entries) {
    archive.addFile(ArchiveFile(
      'image_${entry.key}.png',
      entry.value.length,
      entry.value,
    ));
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

class _NoSubscriptionRefreshViewmodel extends GenerationPageViewmodel {
  @override
  Future<void> refreshSubscriptionSnapshot() async {}
}

class _WorkerRecordingViewmodel extends GenerationPageViewmodel {
  _WorkerRecordingViewmodel()
      : super(preparationFeedbackBarrier: _skipPreparationFeedbackBarrier);

  final List<int> createdWorkers = [];
  final List<int> createdTasks = [];
  I2iRequestBatch? lastPresetBatch;
  int? lastSeedOverride;
  String? lastPromptSuffix;
  EnhanceRequestOptions? lastEnhanceOptions;
  BatchToolSnapshot? lastToolSnapshot;

  @override
  Command<void, InfoCardContent> createGenerationCommand({
    required int workerIndex,
    I2iRequestBatch? presetBatch,
    int? seedOverride,
    String promptSuffix = '',
    EnhanceRequestOptions? enhanceOptions,
    BatchToolSnapshot? toolSnapshot,
  }) {
    createdWorkers.add(workerIndex);
    lastPresetBatch = presetBatch;
    lastSeedOverride = seedOverride;
    lastPromptSuffix = promptSuffix;
    lastEnhanceOptions = enhanceOptions;
    lastToolSnapshot = toolSnapshot;
    return Command.createAsyncNoParam(
      () async => InfoCardContent(
        title: 'worker-$workerIndex',
        info: '',
        additionalInfo: const {},
      ),
      initialValue: InfoCardContent.fromEmpty(),
    );
  }

  @override
  Command<void, InfoCardContent> createScheduledGenerationCommand({
    required int workerIndex,
    required GenerationLease lease,
  }) {
    createdTasks.add(lease.taskNumber);
    return createGenerationCommand(workerIndex: workerIndex);
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

  testWidgets('pending token count never delays actual generation submission',
      (tester) async {
    final config = GetIt.I<PayloadConfig>()..promptMode = PromptMode.fixed;
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.rootPromptConfig =
        PayloadConfig.fixedPromptConfig('a girl with blue eyes');
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;
    final pendingCount = Completer<List<int>>();
    var countCalls = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PromptTokenUsage(
                metadata: const {
          "model": "nai-diffusion-5-full",
          "input": "previous image",
          "negative_prompt": "",
        },
                counter: (_, __) {
                  countCalls++;
                  return pendingCount.future;
                }))));
    await tester.pump(const Duration(milliseconds: 200));
    expect(countCalls, 1);
    final bytes =
        Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)));
    final api = _FakeApiService(
        ApiResponse(status: '200', data: directorResponseZip([bytes])));
    final vm = GenerationPageViewmodel(
        apiService: api, fileService: _RecordingFileService());
    vm.startGeneration();
    await waitForCurrentCommand(tester, vm);
    expect(api.calls, 1);
    expect(pendingCount.isCompleted, isFalse);
    expect(PromptTokenSnapshots.instance.latest(config)!.positive,
        ['a girl with blue eyes']);
    expect(vm.commandList.single.value.imageBytes, isNotNull);
    vm.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    pendingCount.complete([5, 0]);
    await tester.pump();
  });

  testWidgets(
      'successful corrupt response is never automatically submitted again',
      (tester) async {
    final bytes = Uint8List.fromList([80, 75, 3, 4, 0]);
    final api = _FakeApiService(ApiResponse(status: '200', data: bytes));
    final vm = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;
    vm.startGeneration();
    await waitForCurrentCommand(tester, vm);
    await tester.pump(const Duration(seconds: 6));
    await waitForCurrentCommand(tester, vm);
    await tester.pump(const Duration(seconds: 16));
    await waitForCurrentCommand(tester, vm);
    expect(api.calls, 1);
    final retained = vm.commandList.single.value.receivedResponses.single;
    expect(retained.bytes, orderedEquals(bytes));
    expect(retained.logicalTaskId, startsWith('generation:'));
    expect(retained.logicalTaskId, endsWith(':1'));
    expect(retained.responseIndex, 0);
    expect(
        vm.commandList.single.value
            .copyWith(anlasRemaining: 42)
            .receivedResponses
            .single,
        same(retained));
    expect(vm.commandStatus.currentGenerationCount, 0);
    expect(vm.commandStatus.isWaitingForNextGeneration.value, isFalse);
    expect(vm.commandList.single.value.info,
        contains('automatic resubmission stopped'));
    vm.dispose();
  });

  testWidgets('successful infill response survives local compositing failure',
      (tester) async {
    final source = img.Image(width: 64, height: 64, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(20, 100, 180, 255));
    final mask = img.Image(width: 64, height: 64, numChannels: 3);
    img.fill(mask, color: img.ColorRgb8(255, 255, 255));
    final response = directorResponseZip([
      Uint8List.fromList(img.encodePng(img.Image(width: 32, height: 32))),
    ]);
    final api = _FakeApiService(ApiResponse(status: '200', data: response));
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.i2iConfig
      ..setImage(Uint8List.fromList(img.encodePng(source)))
      ..setMask(Uint8List.fromList(img.encodePng(mask)), []);
    config.i2iEnabled = true;
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;
    final prepared = await tester.runAsync(() =>
        PrepareI2iRequestUseCase(config: config.i2iConfig)
            .planBatch(targetWidth: 64, targetHeight: 64));
    final vm = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
      prepareI2iBatch: (
              {required config,
              required targetWidth,
              required targetHeight,
              required transparentBackground}) async =>
          prepared,
    );
    vm.startGeneration();
    for (var attempt = 0;
        attempt < 100 && vm.commandList.single.value.receivedResponses.isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 1));
    }
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 16));
    expect(api.calls, 1);
    final content = vm.commandList.single.value;
    expect(content.info, contains('automatic resubmission stopped'));
    expect(content.info, contains('does not match'));
    expect(content.receivedResponses.single.bytes, orderedEquals(response));
    expect(
        vm.commandStatus.outcomeUnknownFor(vm.commandList.single), isNotNull);
    vm.dispose();
  });

  test('Enhance prepares once in background and forwards website overrides',
      () async {
    final viewmodel = _WorkerRecordingViewmodel();
    final config = GetIt.I<PayloadConfig>();
    final originalPrompt = List<String>.of(config.rootPromptConfig.strs);
    final originalSeed = config.paramConfig.seed;
    final sourceImage = img.Image(width: 64, height: 64, numChannels: 3);
    img.fill(sourceImage, color: img.ColorRgb8(60, 90, 150));
    final sourceBytes = Uint8List.fromList(img.encodePng(sourceImage));
    config.enhanceConfig.setImage(sourceBytes);

    final firstRun = viewmodel.runEnhanceGeneration();
    expect(viewmodel.isPreparingEnhance, isTrue);
    expect(await viewmodel.runEnhanceGeneration(), isFalse);
    expect(await firstRun, isTrue);

    expect(viewmodel.isPreparingEnhance, isFalse);
    expect(viewmodel.createdWorkers, [0]);
    expect(viewmodel.lastSeedOverride, inInclusiveRange(0, 0xFFFFFFFF));
    expect(viewmodel.lastPromptSuffix, isEmpty);
    expect(viewmodel.lastPresetBatch?.plans, hasLength(1));
    final plan = viewmodel.lastPresetBatch!.plans.single;
    final prepared = img.decodePng(base64Decode(plan.imageB64))!;
    expect(prepared.width, plan.width);
    expect(prepared.height, plan.height);
    expect(prepared.getPixel(0, 0).r, 60);
    expect(config.enhanceConfig.imageBytes, sourceBytes);
    expect(plan.width, config.enhanceConfig.targetSize.width);
    expect(plan.height, config.enhanceConfig.targetSize.height);
    expect(plan.strength, config.enhanceConfig.strength);
    expect(plan.noise, config.enhanceConfig.noise);
    expect(config.rootPromptConfig.strs, originalPrompt);
    expect(config.paramConfig.seed, originalSeed);
  });

  test('Max prepares the original size and retains source transparency',
      () async {
    final viewmodel = _WorkerRecordingViewmodel();
    final config = GetIt.I<PayloadConfig>();
    final image = img.Image(width: 64, height: 64, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(60, 90, 150, 128));
    config.enhanceConfig.setImage(Uint8List.fromList(img.encodePng(image)));
    config.enhanceConfig.selectMax();
    expect(await viewmodel.runEnhanceGeneration(), isTrue);
    expect(viewmodel.lastEnhanceOptions?.upscale, isTrue);
    final plan = viewmodel.lastPresetBatch!.plans.single;
    expect(plan.width, 64);
    expect(plan.height, 64);
    final prepared = img.decodePng(base64Decode(plan.imageB64))!;
    expect(prepared.width, 64);
    expect(prepared.getPixel(0, 0).a, 128);
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
      prepareDirectorToolRequest:
          const _PassthroughPrepareDirectorToolRequestUseCase(),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
    );
    final payload = GetIt.I<PayloadConfig>();
    payload.settings.debugApiEnabled = true;
    payload.directorToolConfig.setImage(coloredPng(80, 80, 80));

    expect(await viewmodel.runDirectorTool(), isTrue);
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

  testWidgets('Director Tools send Takoma its multipart augment request', (
    tester,
  ) async {
    final api = _FakeApiService(ApiResponse(
      status: '500',
      data: Uint8List.fromList(utf8.encode('{"message":"expected failure"}')),
    ));
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      prepareDirectorToolRequest:
          const _PassthroughPrepareDirectorToolRequestUseCase(),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
    );
    final payload = GetIt.I<PayloadConfig>();
    final settings = payload.settings;
    settings.updatePrimaryApiKey('takoma-test-token');
    settings.apiTokens
      ..clear()
      ..add(ApiTokenConfig(
        label: 'Takoma',
        token: 'takoma-test-token',
        isPrimary: true,
        apiBaseUrl: 'https://api.takoma.app',
      ));
    final sourceBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 32, height: 32, numChannels: 3)),
    );
    payload.directorToolConfig.setImage(sourceBytes);

    expect(await viewmodel.runDirectorTool(), isTrue);
    await tester.pumpAndSettle();

    final request = api.requests.single;
    expect(request.endpoint, 'https://api.takoma.app/ai/augment-image');
    final parts = request.multipart!.parts;
    expect(parts.map((part) => part.field), ['image', 'request']);
    expect(parts.first.fileName, 'blob');
    expect(parts.first.contentType, 'image/png');
    expect(parts.first.bytes, sourceBytes);
    expect(parts.last.fileName, 'blob');
    expect(parts.last.contentType, 'application/json');
    final form =
        jsonDecode(utf8.decode(parts.last.bytes)) as Map<String, dynamic>;
    expect(form['req_type'], 'bg-removal');
    expect(form['image'], 'image');
    expect(form['width'], 32);
    expect(form['height'], 32);
    viewmodel.dispose();
  });

  testWidgets('Director Tools keep the JSON body for official NovelAI', (
    tester,
  ) async {
    final api = _FakeApiService(ApiResponse(
      status: '500',
      data: Uint8List.fromList(utf8.encode('{"message":"expected failure"}')),
    ));
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      prepareDirectorToolRequest:
          const _PassthroughPrepareDirectorToolRequestUseCase(),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
    );
    final payload = GetIt.I<PayloadConfig>();
    payload.settings.updatePrimaryApiKey('official-test-token');
    payload.directorToolConfig.setImage(Uint8List.fromList(
      img.encodePng(img.Image(width: 32, height: 32, numChannels: 3)),
    ));

    expect(await viewmodel.runDirectorTool(), isTrue);
    await tester.pumpAndSettle();

    final request = api.requests.single;
    expect(request.endpoint, 'https://image.novelai.net/ai/augment-image');
    expect(request.multipart, isNull);
    expect(request.payload['req_type'], 'bg-removal');
    expect(base64Decode(request.payload['image'] as String), isNotEmpty);
    viewmodel.dispose();
  });

  testWidgets(
      'Director storage failure keeps its paid result and retries only storage',
      (tester) async {
    final outputImage = img.Image(width: 32, height: 32, numChannels: 3);
    final outputBytes = Uint8List.fromList(img.encodePng(outputImage));
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([outputBytes, outputBytes, outputBytes]),
    ));
    final files = _FailOnceFileService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
      prepareDirectorToolRequest:
          const _PassthroughPrepareDirectorToolRequestUseCase(),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
    );
    final payload = GetIt.I<PayloadConfig>();
    payload.settings.debugApiEnabled = true;
    payload.directorToolConfig.setImage(outputBytes);

    expect(await viewmodel.runDirectorTool(), isTrue);
    for (var attempt = 0;
        attempt < 100 &&
            viewmodel.currentCommand?.value.imageArtifact?.status !=
                GeneratedImageStorageStatus.failed;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(api.calls, 1);
    expect(viewmodel.currentCommand?.value.imageBytes, outputBytes);
    expect(
      viewmodel.currentCommand?.value.imageArtifact?.status,
      GeneratedImageStorageStatus.failed,
    );

    await viewmodel.currentCommand!.value.retryImageStorage!();

    expect(api.calls, 1);
    expect(
      viewmodel.currentCommand?.value.imageArtifact?.status,
      GeneratedImageStorageStatus.saved,
    );
    viewmodel.dispose();
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
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      prepareDirectorToolRequest:
          const _PassthroughPrepareDirectorToolRequestUseCase(),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
    );
    final payload = GetIt.I<PayloadConfig>();
    payload.settings.debugApiEnabled = true;
    final source = img.Image(width: 32, height: 32, numChannels: 3);
    payload.directorToolConfig.setImage(
      Uint8List.fromList(img.encodePng(source)),
    );

    expect(await viewmodel.runDirectorTool(), isTrue);
    await tester.pumpAndSettle();

    final error = viewmodel.commandList.single.value.info;
    expect(error, contains('NovelAI server timed out'));
    expect(error, contains('HTTP 500'));
    expect(error, isNot(contains('End of Central Directory')));
    expect(
        viewmodel.commandStatus.outcomeUnknownFor(viewmodel.commandList.single),
        isNull);
    viewmodel.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets('Director Tools normalizes oversized sources like the website', (
    tester,
  ) async {
    final api = _FakeApiService(ApiResponse(
      status: '500',
      data: Uint8List.fromList(utf8.encode('{"message":"expected failure"}')),
    ));
    final requestImage = img.Image(width: 8, height: 8, numChannels: 3);
    final requestBytes = Uint8List.fromList(img.encodePng(requestImage));
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      prepareDirectorToolRequest: _FakePrepareDirectorToolRequestUseCase(
        PreparedDirectorToolImage(
          imageB64: base64Encode(requestBytes),
          width: 1773,
          height: 1773,
        ),
      ),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
    );
    final source = img.Image(width: 64, height: 64, numChannels: 3);
    img.fill(source, color: img.ColorRgb8(30, 60, 90));
    GetIt.I<PayloadConfig>().directorToolConfig.setImage(
          Uint8List.fromList(img.encodePng(source)),
        );

    expect(await viewmodel.runDirectorTool(), isTrue);
    await tester.pumpAndSettle();

    final request = api.requests.single.payload;
    expect(request['width'], 1773);
    expect(request['height'], 1773);
    expect(base64Decode(request['image'] as String), requestBytes);
    viewmodel.dispose();
  });

  test('Director Tools exposes preparation failures once', () async {
    final viewmodel = GenerationPageViewmodel(
      prepareDirectorToolRequest:
          const _FailingPrepareDirectorToolRequestUseCase(),
      preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
    );
    final source = img.Image(width: 64, height: 64, numChannels: 3);
    GetIt.I<PayloadConfig>().directorToolConfig.setImage(
          Uint8List.fromList(img.encodePng(source)),
        );

    expect(await viewmodel.runDirectorTool(), isFalse);
    expect(
      viewmodel.takeDirectorPreparationError(),
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        'invalid Director source',
      ),
    );
    expect(viewmodel.takeDirectorPreparationError(), isNull);
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

  testWidgets('V5 result appears before Opus usage settles in the background', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final observedAt = DateTime.now();
    final settlement = Completer<SubscriptionInfo?>();
    final accounts = _FakeAccountService(responses: [
      SubscriptionInfo(
        anlas: 100,
        tier: 3,
        active: true,
        usage: OpusUsage(
          percent: 73,
          isNegative: false,
          secondsPerPercent: 6048,
          observedAt: observedAt,
        ),
      ),
    ], blocker: settlement);
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: _RecordingFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..apiKey = 'pst-test'
      ..debugApiEnabled = false;
    await viewmodel.refreshSubscriptionSnapshot();

    viewmodel.runSingleGeneration();
    final command = viewmodel.currentCommand!;
    await waitForCurrentCommand(tester, viewmodel);

    expect(command.value.imageBytes, isNotNull);
    expect(command.value.opusUsage?.visiblePercent.round(), 73);
    expect(command.value.opusUsageIsEstimated, isTrue);
    expect(command.value.opusUsageSettling, isTrue);

    settlement.complete(SubscriptionInfo(
      anlas: 100,
      tier: 3,
      active: true,
      usage: OpusUsage(
        percent: 72,
        isNegative: false,
        secondsPerPercent: 6048,
        observedAt: observedAt.add(const Duration(seconds: 1)),
      ),
    ));

    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (command.value.opusUsageSettling &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(command.value.opusUsage?.visiblePercent.round(), 72);
    expect(command.value.opusUsageIsEstimated, isFalse);
    expect(command.value.opusUsageSettling, isFalse);
    viewmodel.dispose();
  });

  testWidgets('finite V5 batch coalesces per-result subscription refreshes', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final accounts = _ChangingOpusAccountService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: _RecordingFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..apiKey = 'pst-test'
      ..debugApiEnabled = false
      ..generationCount = 4
      ..generationIntervalSec = 0;
    await viewmodel.refreshSubscriptionSnapshot();

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 500 &&
            (viewmodel.commandStatus.isGenerationActive.value ||
                viewmodel.commandList.any(
                  (command) => command.value.opusUsageSettling,
                ));
        attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();

    expect(api.calls, 4);
    expect(
      viewmodel.commandList.where(
        (command) => command.value.imageBytes != null,
      ),
      hasLength(4),
    );
    expect(
      viewmodel.commandList
          .where((command) => command.value.imageBytes != null)
          .map((command) => command.value.opusUsageSettling),
      everyElement(isFalse),
    );
    // Initial snapshot + one batch baseline + one final settlement.
    expect(accounts.calls, 3);
    viewmodel.dispose();
  });

  testWidgets('longer V5 batch refreshes Opus usage every five results', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final accounts = _ChangingOpusAccountService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: _RecordingFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..apiKey = 'pst-test'
      ..debugApiEnabled = false
      ..generationCount = 5
      ..generationIntervalSec = 0;
    await viewmodel.refreshSubscriptionSnapshot();

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 500 &&
            (viewmodel.commandStatus.isGenerationActive.value ||
                viewmodel.commandList.any(
                  (command) => command.value.opusUsageSettling,
                ));
        attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();

    expect(api.calls, 5);
    expect(
      viewmodel.commandList
          .where((command) => command.value.imageBytes != null)
          .map((command) => command.value.opusUsageSettling),
      everyElement(isFalse),
    );
    // Initial snapshot + baseline + one five-result refresh + final settlement.
    expect(accounts.calls, 4);
    viewmodel.dispose();
  });

  testWidgets('a winning generation is published through image storage',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final outputBytes = Uint8List.fromList(img.encodePng(outputImage));
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([outputBytes]),
    ));
    final files = _RecordingFileService();
    final storage = _RecordingGeneratedImageStorage(
      PngGeneratedImageStorage(fileService: files),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
      generatedImageStorage: storage,
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0
      ..outputFolderPath = '/chosen-output';

    viewmodel.startGeneration();
    await waitForCurrentCommand(tester, viewmodel);

    expect(storage.requests, hasLength(1));
    expect(storage.requests.single.pngBytes, outputBytes);
    expect(storage.requests.single.fileName, files.savedNames.single);
    expect(storage.requests.single.logicalTaskId, contains('generation:1'));
    expect(
      storage.requests.single.storagePolicy.pngOutputDirectory,
      '/chosen-output',
    );
    expect(storage.requests.single.storagePolicy.jpegEnabled, isFalse);
    expect(storage.requests.single.storagePolicy.requestOfficialWebp, isFalse);
    expect(
      (api.requests.single.payload['parameters'] as Map)
          .containsKey('image_format'),
      isFalse,
    );
    final content = viewmodel.currentCommand!.value;
    expect(content.imageArtifact, same(storage.submissions.single.artifact));
    expect(
      identical(content.imageBytes, storage.requests.single.pngBytes),
      isTrue,
    );
    expect(content.imageArtifact?.status, GeneratedImageStorageStatus.saved);
    expect(content.currentImageFile?.path, '/test/${files.savedNames.single}');
    expect(viewmodel.commandStatus.currentGenerationCount, 1);
    viewmodel.dispose();
  });

  testWidgets('storage format and folder policy are immutable per request',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 4);
    img.fill(outputImage, color: img.ColorRgba8(20, 40, 60, 255));
    final api = _BlockingApiService();
    final files = _RecordingFileService();
    final storage = _RecordingGeneratedImageStorage(
      PngGeneratedImageStorage(fileService: files),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
      generatedImageStorage: storage,
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0
      ..outputFolderPath = '/accepted-output'
      ..imageSaveFormat = GeneratedImageSaveFormat.webp;

    viewmodel.startGeneration();
    await tester.pump(const Duration(milliseconds: 1));
    expect(api.calls, 1);

    settings
      ..outputFolderPath = '/later-output'
      ..imageSaveFormat = GeneratedImageSaveFormat.png;
    api.response.complete(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    await waitForCurrentCommand(tester, viewmodel);

    final request = storage.requests.single;
    expect(request.storagePolicy.pngOutputDirectory, '/accepted-output');
    expect(request.storagePolicy.requestOfficialWebp, isTrue);
    viewmodel.dispose();
  });

  testWidgets('desktop JPEG settings are captured in the storage request',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(outputImage)),
        ]),
      ));
      final files = _RecordingFileService();
      final storage = _RecordingGeneratedImageStorage(
        PngGeneratedImageStorage(fileService: files),
      );
      final viewmodel = GenerationPageViewmodel(
        apiService: api,
        fileService: files,
        generatedImageStorage: storage,
      );
      final settings = GetIt.I<PayloadConfig>().settings;
      settings
        ..debugApiEnabled = true
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..outputFolderPath = '/shared-output'
        ..imageSaveFormat = GeneratedImageSaveFormat.jpegWithoutMetadata;

      viewmodel.startGeneration();
      await waitForCurrentCommand(tester, viewmodel);

      final policy = storage.requests.single.storagePolicy;
      expect(policy.jpegEnabled, isTrue);
      expect(policy.jpegIncludesMetadata, isFalse);
      expect(policy.requestOfficialWebp, isFalse);
      expect(policy.jpegOutputDirectory, '/shared-output');
      expect(policy.pngOutputDirectory, '/shared-output');
      viewmodel.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile generation ignores persisted desktop JPEG settings',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(outputImage)),
        ]),
      ));
      final files = _RecordingFileService();
      final storage = _RecordingGeneratedImageStorage(
        PngGeneratedImageStorage(fileService: files),
      );
      final viewmodel = GenerationPageViewmodel(
        apiService: api,
        fileService: files,
        generatedImageStorage: storage,
      );
      final settings = GetIt.I<PayloadConfig>().settings;
      settings
        ..debugApiEnabled = true
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..outputFolderPath = '/png-output'
        ..imageSaveFormat = GeneratedImageSaveFormat.jpegWithMetadata;

      viewmodel.startGeneration();
      await waitForCurrentCommand(tester, viewmodel);

      expect(storage.requests.single.storagePolicy.jpegEnabled, isFalse);
      expect(
        storage.requests.single.storagePolicy.pngOutputDirectory,
        '/png-output',
      );
      viewmodel.dispose();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the winning PNG is visible while durable storage is pending',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final outputBytes = Uint8List.fromList(img.encodePng(outputImage));
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([outputBytes]),
    ));
    final storage = _DelayedGeneratedImageStorage();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
      generatedImageStorage: storage,
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 20 && storage.submission == null;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    final command = viewmodel.currentCommand!;
    expect(storage.submission, isNotNull);
    expect(command.isExecuting.value, isFalse);
    expect(
      command.value.imageArtifact,
      same(storage.submission!.artifact),
    );
    expect(command.value.imageBytes, outputBytes);
    expect(
      command.value.imageArtifact?.status,
      GeneratedImageStorageStatus.saving,
    );
    expect(viewmodel.commandStatus.currentGenerationCount, 1);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: InfoCard(command: command)),
    ));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    storage.publication.complete(const GeneratedImageFile(
      path: '/test/generated.png',
      mediaType: 'image/png',
      isPermanent: true,
    ));
    for (var attempt = 0;
        attempt < 100 &&
            command.value.imageArtifact?.status !=
                GeneratedImageStorageStatus.saved;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(command.isExecuting.value, isFalse);
    expect(
      command.value.imageArtifact?.status,
      GeneratedImageStorageStatus.saved,
    );
    expect(viewmodel.commandStatus.currentGenerationCount, 1);
    viewmodel.dispose();
  });

  testWidgets('pending JPEG storage does not occupy the API worker',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final response = ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    );
    final api = _SequenceApiService([response, response]);
    final storage = _QueuedDelayedGeneratedImageStorage();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
      generatedImageStorage: storage,
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 2
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 100 && storage.submissions.length < 2;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(api.requests, hasLength(2));
    expect(storage.submissions, hasLength(2));
    expect(viewmodel.commandStatus.currentGenerationCount, 2);
    expect(
      storage.submissions.map((submission) => submission.artifact.status),
      everyElement(GeneratedImageStorageStatus.saving),
    );

    for (var index = 0; index < storage.publications.length; index++) {
      storage.publications[index].complete(GeneratedImageFile(
        path: '/test/result-$index.png',
        mediaType: 'image/png',
        isPermanent: true,
      ));
    }
    for (var attempt = 0;
        attempt < 100 &&
            storage.submissions.any((submission) =>
                submission.artifact.status !=
                GeneratedImageStorageStatus.saved);
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(viewmodel.commandStatus.currentGenerationCount, 2);
    expect(viewmodel.commandStatus.isGenerationActive.value, isFalse);
    viewmodel.dispose();
  });

  testWidgets('storage retry reuses paid bytes without a second API request',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final response = ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    );
    final api = _SequenceApiService([response, response]);
    final files = _FailOnceFileService();
    final storage = _RecordingGeneratedImageStorage(
      PngGeneratedImageStorage(fileService: files),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
      generatedImageStorage: storage,
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 100 &&
            (storage.submissions.isEmpty ||
                storage.submissions.first.artifact.status !=
                    GeneratedImageStorageStatus.failed);
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(api.requests, hasLength(1));
    expect(storage.submissions, hasLength(1));
    expect(
      storage.submissions.first.artifact.status,
      GeneratedImageStorageStatus.failed,
    );
    expect(viewmodel.commandList.single.value.imageBytes, isNotNull);

    await viewmodel.commandList.single.value.retryImageStorage!();
    for (var attempt = 0;
        attempt < 100 && viewmodel.commandStatus.currentGenerationCount < 1;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(api.requests, hasLength(1));
    expect(storage.submissions, hasLength(2));
    expect(
      storage.requests.map((request) => request.logicalTaskId).toSet(),
      hasLength(1),
    );
    expect(
      identical(
        storage.requests.first.pngBytes,
        storage.requests.last.pngBytes,
      ),
      isTrue,
    );
    expect(
      storage.requests.map((request) => request.fileName).toSet(),
      hasLength(1),
    );
    expect(
      storage.submissions.last.artifact.status,
      GeneratedImageStorageStatus.saved,
    );
    expect(viewmodel.commandStatus.currentGenerationCount, 1);
    expect(viewmodel.commandList, hasLength(1));
    expect(viewmodel.commandList.single.value.imageArtifact, isNotNull);
    viewmodel.dispose();
  });

  testWidgets('WebP format requests and saves the official WebP unchanged',
      (tester) async {
    final webp =
        base64Decode('UklGRh4AAABXRUJQVlA4TBEAAAAvAUAAAAdQiirUo/+BiOh/AAA=');
    final archive = Archive()
      ..addFile(ArchiveFile('image_0.webp', webp.length, webp));
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: Uint8List.fromList(ZipEncoder().encode(archive)!),
    ));
    final files = _RecordingFileService();
    final storage = _RecordingGeneratedImageStorage(
      PngGeneratedImageStorage(fileService: files),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
      generatedImageStorage: storage,
    );
    GetIt.I<PayloadConfig>().settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0
      ..imageSaveFormat = GeneratedImageSaveFormat.webp;

    viewmodel.startGeneration();
    await waitForCurrentCommand(tester, viewmodel);

    expect(
      (api.requests.single.payload['parameters'] as Map)['image_format'],
      'webp',
    );
    expect(storage.requests.single.pngBytes, webp);
    expect(files.savedNames.single, endsWith('.webp'));
    expect(files.savedBytes.single, webp);
    final content = viewmodel.currentCommand!.value;
    expect(content.currentImageFile?.mediaType, 'image/webp');
    expect(content.imageBytes, webp);
    viewmodel.dispose();
  });

  testWidgets('one paid response publishes every ordered sample once',
      (tester) async {
    final images = List.generate(3, (index) {
      final image = img.Image(width: 32, height: 32, numChannels: 3);
      img.fill(image, color: img.ColorRgb8(index * 40, 20, 30));
      return Uint8List.fromList(img.encodePng(image));
    });
    final api = _SequenceApiService([
      ApiResponse(status: '200', data: directorResponseZip(images)),
    ]);
    final files = _RecordingFileService();
    final storage = _RecordingGeneratedImageStorage(
      PngGeneratedImageStorage(fileService: files),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
      generatedImageStorage: storage,
    );
    final payload = GetIt.I<PayloadConfig>();
    payload.paramConfig.nSamples = 3;
    payload.settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 100 && viewmodel.commandList.length < 3;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(api.requests, hasLength(1));
    expect(storage.requests, hasLength(3));
    expect(viewmodel.commandList, hasLength(3));
    expect(
      storage.requests.map((request) => request.logicalTaskId),
      containsAllInOrder([
        contains(':sample:0'),
        contains(':sample:1'),
        contains(':sample:2'),
      ]),
    );
    expect(
      viewmodel.commandList.map((command) => command.value.imageBytes),
      hasLength(3),
    );
    expect(
      viewmodel.commandList.where((command) => command.value.anlasCost != null),
      hasLength(1),
    );
    viewmodel.dispose();
  });

  testWidgets(
      'a damaged multi-sample member keeps valid original sample identities',
      (tester) async {
    Uint8List sample(int red) {
      final image = img.Image(width: 32, height: 32, numChannels: 3);
      img.fill(image, color: img.ColorRgb8(red, 20, 30));
      return Uint8List.fromList(img.encodePng(image));
    }

    final api = _SequenceApiService([
      ApiResponse(
        status: '200',
        data: indexedResponseZip({
          0: sample(10),
          1: Uint8List.fromList(utf8.encode('damaged sample')),
          2: sample(30),
        }),
      ),
    ]);
    final files = _RecordingFileService();
    final storage = _RecordingGeneratedImageStorage(
      PngGeneratedImageStorage(fileService: files),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
      generatedImageStorage: storage,
    );
    final payload = GetIt.I<PayloadConfig>();
    payload.paramConfig.nSamples = 3;
    payload.settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 100 && viewmodel.commandList.length < 2;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 1));
    }

    expect(api.requests, hasLength(1));
    expect(storage.requests, hasLength(2));
    expect(
      storage.requests.map((request) => request.logicalTaskId),
      containsAllInOrder([
        contains(':sample:0'),
        contains(':sample:2'),
      ]),
    );
    expect(
      viewmodel.commandList.map(
        (command) => command.value.additionalInfo['sample_index'],
      ),
      containsAllInOrder([0, 2]),
    );
    expect(
      viewmodel.commandList.first.value.additionalInfo['response_warning'],
      contains('sample 2'),
    );
    expect(
      viewmodel.commandList.where((command) => command.value.anlasCost != null),
      hasLength(1),
    );
    viewmodel.dispose();
  });

  testWidgets('pending Vibe encoding contributes two Anlas to next cost', (
    tester,
  ) async {
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-4-5-full';
    config.settings
      ..subscriptionTier = 3
      ..subscriptionActive = true
      ..subscriptionStatusKnown = true;
    config.vibeConfigListV4.add(VibeConfigV4(
      fileName: 'pending.png',
      referenceStrength: 0.6,
      imageBytes: Uint8List.fromList([1, 2, 3]),
    ));
    config.setVibeEnabled(true);
    final viewmodel = _NoSubscriptionRefreshViewmodel();

    viewmodel.refreshCostEstimate();
    await tester.pump();

    expect(viewmodel.nextCostEstimate.value?.anlas, 2);
    expect(viewmodel.nextCostEstimate.value?.isFreeUnderOpus, isFalse);
    viewmodel.dispose();
  });

  testWidgets(
      'displayed reference cost matches payload capabilities for every model family',
      (tester) async {
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig
      ..sizes = const [GenerationSize(width: 1024, height: 1024)]
      ..steps = 28
      ..nSamples = 1;
    config.settings
      ..subscriptionTier = 0
      ..subscriptionActive = false
      ..subscriptionStatusKnown = true;
    config.vibeConfigList.addAll(List.generate(
      6,
      (index) => VibeConfig(
        imageB64: 'legacy-$index',
        fileName: 'legacy-$index.png',
        infoExtracted: 1,
        referenceStrength: 0.3,
      ),
    ));
    config.vibeConfigListV4.addAll(List.generate(
      6,
      (index) => VibeConfigV4(
        fileName: 'modern-$index.naiv4vibe',
        vibeB64: 'modern-$index',
        referenceStrength: 0.3,
      ),
    ));
    config.preciseReferenceConfigList.addAll(List.generate(
      2,
      (index) => PreciseReferenceConfig(
        imageB64: 'precise-$index',
        fileName: 'precise-$index.png',
      ),
    ));
    // Exercise imported residual state too: capability resolution, not these
    // booleans alone, decides which resources enter the request and estimate.
    config
      ..vibeEnabled = true
      ..preciseReferenceEnabled = true;
    final viewmodel = _NoSubscriptionRefreshViewmodel();

    for (final model in [
      'nai-diffusion-3',
      'nai-diffusion-4-full',
      'nai-diffusion-4-5-full',
      'nai-diffusion-5-full',
    ]) {
      config.paramConfig.model = model;
      final payload = GeneratePayloadUseCase(payloadConfig: config)().payload;
      final parameters = payload['parameters'] as Map<String, dynamic>;
      final actualVibes =
          (parameters['reference_image_multiple'] as List?)?.length ?? 0;
      final actualPrecise =
          (parameters['director_reference_images'] as List?)?.length ?? 0;
      final base = estimateAnlasCost(
        width: 1024,
        height: 1024,
        steps: 28,
        model: model,
        sm: parameters['sm'] == true,
        smDyn: parameters['sm_dyn'] == true,
      );
      final expected = base.anlas +
          actualPrecise * preciseReferenceAnlas +
          max(0, actualVibes - freeVibeCount) * extraVibeAnlas;

      viewmodel.refreshCostEstimate();
      await tester.pump();

      expect(
        viewmodel.nextCostEstimate.value?.anlas,
        expected,
        reason: '$model estimate must represent only payload resources',
      );
    }
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
    GetIt.I<PayloadConfig>().paramConfig.model = 'nai-diffusion-4-5-full';
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

  testWidgets('batch retries a temporarily unavailable final balance', (
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
      null,
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
    await tester.pump(const Duration(seconds: 5));

    final content = viewmodel.currentCommand!.value;
    expect(accounts.calls, 4);
    expect(content.anlasCost, 20);
    expect(content.anlasCostIsEstimated, isFalse);
    expect(content.anlasRemaining, 80);
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

  testWidgets(
      'retryable service errors back off and pause an account after five', (
    tester,
  ) async {
    final api = _FakeApiService(ApiResponse(
      status: '503',
      data: Uint8List.fromList(utf8.encode(
        '{"statusCode":503,"message":"service unavailable"}',
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

    for (var attempt = 3; attempt <= 5; attempt++) {
      await tester.pump(const Duration(seconds: 14));
      expect(api.calls, attempt - 1);
      await tester.pump(const Duration(seconds: 1));
      await waitForCurrentCommand(tester, viewmodel);
      expect(api.calls, attempt);
    }
    expect(viewmodel.commandStatus.isGenerationActive.value, isFalse);
    expect(
      viewmodel.commandList.last.value.info,
      contains('pause after five consecutive failures'),
    );
    viewmodel.dispose();
  });

  testWidgets('a retry reuses its task card and stable task file number', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _SequenceApiService([
      ApiResponse(
        status: '500',
        data: Uint8List.fromList(utf8.encode('{"message":"retry"}')),
      ),
      ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(outputImage)),
        ]),
      ),
    ]);
    final files = _RecordingFileService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: files,
    );
    final config = GetIt.I<PayloadConfig>();
    config.rootPromptConfig =
        PromptConfig(strs: ['__A__ + __A__'], prompts: [], shuffled: false);
    config.savedPromptConfigList = [
      PromptConfig(
          comment: 'A',
          selectionMethod: 'single_sequential',
          strs: ['A1', 'A2', 'A3'],
          prompts: [])
    ];
    final settings = config.settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    await waitForCurrentCommand(tester, viewmodel);

    expect(viewmodel.commandList, hasLength(1));
    expect(viewmodel.commandList.single.value.imageBytes, isNull);

    await tester.pump(const Duration(seconds: 5));
    await waitForCurrentCommand(tester, viewmodel);

    expect(api.requests, hasLength(2));
    expect(viewmodel.commandList, hasLength(1));
    expect(viewmodel.commandList.single.value.imageBytes, isNotNull);
    expect(files.savedNames.single, contains('-000001-'));
    expect(
      api.requests[1].payload['parameters']['seed'],
      api.requests[0].payload['parameters']['seed'],
    );
    expect(api.requests.map((request) => request.payload['input']),
        ['A1 + A1', 'A1 + A1']);
    expect(GeneratePayloadUseCase(payloadConfig: config)().payload['input'],
        'A2 + A2');
    viewmodel.dispose();
  });

  testWidgets('parallel accounts use their own subscription cost snapshots', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final accounts = _PerTokenAccountService(const {
      'pst-opus': SubscriptionInfo(anlas: 100, tier: 3, active: true),
      'pst-standard': SubscriptionInfo(anlas: 100, tier: 1, active: true),
    });
    final settings = GetIt.I<PayloadConfig>().settings;
    GetIt.I<PayloadConfig>().paramConfig.model = 'nai-diffusion-4-5-full';
    settings.updatePrimaryApiKey('pst-opus');
    settings.apiTokens.first.label = 'Opus';
    settings.apiTokens.add(
      ApiTokenConfig(label: 'Standard', token: 'pst-standard'),
    );
    settings
      ..parallelApiEnabled = true
      ..generationCount = 2
      ..generationIntervalSec = 0
      ..debugApiEnabled = false;
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: _RecordingFileService(),
    );

    viewmodel.startGeneration();
    await tester.pumpAndSettle();

    final byLabel = {
      for (final command in viewmodel.commandList)
        command.value.tokenLabel: command.value,
    };
    expect(byLabel['Opus']?.anlasCost, 0);
    expect(byLabel['Standard']?.anlasCost, greaterThan(0));
    accounts.laterCalls.complete(null);
    await tester.pump(const Duration(seconds: 4));
    viewmodel.dispose();
  });

  testWidgets('fresh insufficient balance skips the image request', (
    tester,
  ) async {
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: Uint8List(0),
    ));
    final accounts = _FakeAccountService(responses: const [
      SubscriptionInfo(anlas: 0, tier: 1, active: true),
    ]);
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..updatePrimaryApiKey('pst-empty')
      ..debugApiEnabled = false
      ..generationCount = 1
      ..generationIntervalSec = 0;
    await viewmodel.refreshSubscriptionSnapshot();

    viewmodel.startGeneration();
    await waitForCurrentCommand(tester, viewmodel);

    expect(api.calls, 0);
    expect(viewmodel.commandList.single.value.info, contains('insufficient'));
    viewmodel.stopGeneration();
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets('parallel batch keeps estimated and actual cost per account', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final accounts = _TokenSequenceAccountService(const {
      'pst-a': [
        SubscriptionInfo(anlas: 100, tier: 1, active: true),
        SubscriptionInfo(anlas: 90, tier: 1, active: true),
      ],
      'pst-b': [
        SubscriptionInfo(anlas: 100, tier: 1, active: true),
        SubscriptionInfo(anlas: 80, tier: 1, active: true),
      ],
    });
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.updatePrimaryApiKey('pst-a');
    settings.apiTokens.first.label = 'A';
    settings.apiTokens.add(ApiTokenConfig(label: 'B', token: 'pst-b'));
    settings
      ..parallelApiEnabled = true
      ..generationCount = 2
      ..generationIntervalSec = 0
      ..debugApiEnabled = false;
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: _RecordingFileService(),
    );

    viewmodel.startGeneration();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (viewmodel.commandList.any(
            (command) => command.value.batchAnlasCost == null,
          ) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    final byLabel = {
      for (final command in viewmodel.commandList)
        command.value.tokenLabel: command.value,
    };
    expect(byLabel['A']?.anlasCostIsEstimated, isTrue);
    expect(byLabel['A']?.batchAnlasCost, 10);
    expect(byLabel['B']?.anlasCostIsEstimated, isTrue);
    expect(byLabel['B']?.batchAnlasCost, 20);
    viewmodel.dispose();
  });

  for (final model in [
    'nai-diffusion-5-full',
    'nai-diffusion-5-curated',
    'nai-diffusion-4-5-full'
  ]) {
    for (final transparent in [false, true]) {
      for (final inpaint in [false, true]) {
        testWidgets(
            '$model I2I input alpha is independent of output transparent $transparent, inpaint $inpaint',
            (tester) async {
          final source = img.Image(width: 64, height: 64, numChannels: 4);
          img.fill(source, color: img.ColorRgba8(80, 120, 160, 128));
          final bytes = Uint8List.fromList(img.encodePng(source));
          final api = _FakeApiService(
              ApiResponse(status: '200', data: directorResponseZip([bytes])));
          final vm = GenerationPageViewmodel(
              apiService: api,
              fileService: _RecordingFileService(),
              preparationFeedbackBarrier: () async {});
          final config = GetIt.I<PayloadConfig>();
          config.settings.debugApiEnabled = true;
          config.paramConfig
            ..model = model
            ..transparentBackground = transparent;
          config.i2iConfig
            ..setImage(bytes)
            ..setRequestSize(const GenerationSize(width: 64, height: 64),
                mode: I2iSizeMode.manual);
          if (inpaint) {
            final mask = img.Image(width: 64, height: 64, numChannels: 4);
            img.fill(mask, color: img.ColorRgba8(255, 255, 255, 255));
            config.i2iConfig
                .setMask(Uint8List.fromList(img.encodePng(mask)), []);
          }
          config.noteI2iImported(replacing: false);
          vm.runSingleGeneration();
          for (var i = 0;
              i < 1000 && (vm.currentCommand?.isExecuting.value ?? true);
              i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 2)));
            await tester.pump(const Duration(milliseconds: 10));
          }
          expect(api.requests, hasLength(1),
              reason: vm.currentCommand?.value.info);
          final image = img.decodePng(base64Decode(
              api.requests.single.payload['parameters']['image']))!;
          expect(
              image.getPixel(32, 32).a,
              model.contains('diffusion-5') &&
                      !(inpaint && model.endsWith('curated'))
                  ? 128
                  : 255);
          expect(config.i2iConfig.imageBytes, bytes);
          vm.dispose();
        });
      }
    }
  }

  testWidgets(
      'Curated inpaint preview uses V4.5 fee and changes back for plain I2I',
      (tester) async {
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig
      ..model = 'nai-diffusion-5-curated'
      ..steps = 28;
    config.settings
      ..subscriptionStatusKnown = true
      ..subscriptionActive = false
      ..subscriptionTier = 0;
    final source = img.Image(width: 512, height: 512, numChannels: 4);
    img.fill(source, color: img.ColorRgba8(10, 20, 30, 128));
    config.i2iConfig
      ..setImage(Uint8List.fromList(img.encodePng(source)))
      ..setStrength(.6)
      ..setRequestSize(const GenerationSize(width: 512, height: 512),
          mode: I2iSizeMode.manual);
    final mask = img.Image(width: 512, height: 512, numChannels: 4);
    img.fill(mask, color: img.ColorRgba8(255, 255, 255, 255));
    config.i2iConfig.setMask(Uint8List.fromList(img.encodePng(mask)), []);
    config.noteI2iImported(replacing: false);
    final vm = _NoSubscriptionRefreshViewmodel();
    vm.refreshCostEstimate();
    for (var i = 0; i < 1000 && vm.nextCostEstimate.value == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    final expected = estimateAnlasCost(
        width: 512,
        height: 512,
        steps: 28,
        action: 'infill',
        strength: .6,
        tier: 0,
        subscriptionActive: false,
        model: 'nai-diffusion-4-5-curated-inpainting');
    expect(vm.nextCostEstimate.value?.anlas, expected.anlas);
    expect(config.paramConfig.model, 'nai-diffusion-5-curated');
    config.i2iConfig.removeMask();
    vm.refreshCostEstimate();
    final plainExpected = estimateAnlasCost(
        width: 512,
        height: 512,
        steps: 28,
        action: 'img2img',
        strength: .6,
        tier: 0,
        subscriptionActive: false,
        model: 'nai-diffusion-5-curated');
    expect(plainExpected.anlas, isNot(expected.anlas));
    for (var i = 0;
        i < 1000 && vm.nextCostEstimate.value?.anlas != plainExpected.anlas;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(vm.nextCostEstimate.value?.anlas, plainExpected.anlas);
    vm.dispose();
  });

  testWidgets('homepage generation keeps fixed seed despite legacy I2I flag', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    img.fill(outputImage, color: img.ColorRgb8(20, 40, 60));
    final diagnosticEvents = <GenerationPerformanceEvent>[];
    final api = _FakeApiService(
        ApiResponse(
          status: '200',
          data: directorResponseZip([
            Uint8List.fromList(img.encodePng(outputImage)),
          ]),
        ),
        diagnosticObserver: diagnosticEvents.add);
    final files = _RecordingFileService();
    final accounts = _FakeAccountService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      accountService: accounts,
      fileService: files,
      preparationFeedbackBarrier: () async {},
    );
    final config = GetIt.I<PayloadConfig>();
    config.settings.debugApiEnabled = true;
    config.paramConfig
      ..model = 'nai-diffusion-4-5-full'
      ..randomSeed = false
      ..seed = 424242;
    final sourceBytes = stealthCarrierPng();
    config.i2iConfig
      ..setImage(sourceBytes)
      ..setRequestSize(
        const GenerationSize(width: 13, height: 7),
        mode: I2iSizeMode.manual,
      )
      ..setStrength(0.61)
      ..setNoise(0.17)
      ..setUseRandomSeed(true);
    config.noteI2iImported(replacing: false);

    Future<void> runOneGeneration() async {
      viewmodel.runSingleGeneration();
      for (var attempt = 0;
          attempt < 1000 &&
              (viewmodel.currentCommand?.isExecuting.value ?? true);
          attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(viewmodel.currentCommand?.isExecuting.value, isFalse);
    }

    await runOneGeneration();

    final request = api.requests.first.payload;
    final diagnostics = api.requests.first.diagnosticContext;
    final parameters = request['parameters'] as Map<String, dynamic>;
    final normalized = img.decodePng(base64Decode(parameters['image']))!;
    expect(request['action'], 'img2img');
    expect((normalized.width, normalized.height), (13, 7));
    expect(normalized.numChannels, 4);
    expect(
      rgbaSha256(normalized),
      resizedLandscapeOpaqueRgbaSha256,
    );
    expect(config.i2iConfig.imageBytes, sourceBytes);
    expect(
      (
        img.decodePng(config.i2iConfig.imageBytes!)!.width,
        img.decodePng(config.i2iConfig.imageBytes!)!.height
      ),
      (16, 8),
    );
    expect(parameters['strength'], 0.61);
    expect(parameters['noise'], 0.17);
    expect(parameters['seed'], 424242);
    expect(parameters['extra_noise_seed'], 424241);
    expect(parameters['color_correct'], isFalse);
    expect(parameters['sm'], isFalse);
    expect(parameters['sm_dyn'], isFalse);
    expect(diagnostics, isNotNull);
    expect(diagnostics!.normalizedImageBytes, greaterThan(0));
    expect(diagnostics.correlationId, isNotEmpty);
    expect(
      diagnosticEvents.map((event) => event.stage),
      containsAllInOrder([
        GenerationPerformanceStage.preparationStarted,
        GenerationPerformanceStage.preparationCompleted,
      ]),
    );
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

  testWidgets('homepage uses stable fixed seeds and fresh random task seeds', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
      preparationFeedbackBarrier: () async {},
      prepareI2iBatch: ({
        required config,
        required targetWidth,
        required targetHeight,
        required transparentBackground,
      }) async {
        final plan = I2iRequestPlan(
          imageB64: base64Encode(config.imageBytes!),
          maskB64: null,
          width: targetWidth,
          height: targetHeight,
          strength: config.strength,
          noise: config.noise,
          addOriginalImage: false,
          composite: null,
          summary: 'seed integration test',
        );
        return I2iRequestBatch(
          plans: [plan],
          serial: true,
          summary: plan.summary,
        );
      },
    );
    final config = GetIt.I<PayloadConfig>();
    config.settings.debugApiEnabled = true;
    config.paramConfig
      ..randomSeed = false
      ..seed = 424242;
    config.i2iConfig
      ..setImage(Uint8List.fromList(img.encodePng(outputImage)))
      ..setRequestSize(
        const GenerationSize(width: 64, height: 64),
        mode: I2iSizeMode.manual,
      );
    config.noteI2iImported(replacing: false);

    Future<void> runOneGeneration() async {
      viewmodel.runSingleGeneration();
      await waitForCurrentCommand(tester, viewmodel);
    }

    await runOneGeneration();
    await runOneGeneration();
    expect(
      api.requests.take(2).map((request) =>
          (request.payload['parameters'] as Map<String, dynamic>)['seed']),
      everyElement(424242),
    );

    config.paramConfig.randomSeed = true;
    await runOneGeneration();
    await runOneGeneration();
    final randomParameters = api.requests.skip(2).map(
          (request) => request.payload['parameters'] as Map<String, dynamic>,
        );
    final randomSeeds = randomParameters
        .map((parameters) => parameters['seed'] as int)
        .toList();
    expect(randomSeeds.toSet(), hasLength(2));
    expect(
      randomParameters.map((parameters) => parameters['extra_noise_seed']),
      [
        (randomSeeds[0] - 1) & 0xFFFFFFFF,
        (randomSeeds[1] - 1) & 0xFFFFFFFF,
      ],
    );
    viewmodel.stopGeneration();
    await tester.pumpAndSettle();
    viewmodel.dispose();
  });

  testWidgets('local I2I preparation failure emits a redacted diagnostic', (
    tester,
  ) async {
    final diagnosticEvents = <GenerationPerformanceEvent>[];
    final api = _FakeApiService(
      ApiResponse(status: '200', data: Uint8List(0)),
      diagnosticObserver: diagnosticEvents.add,
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      preparationFeedbackBarrier: () async {},
      prepareI2iBatch: ({
        required config,
        required targetWidth,
        required targetHeight,
        required transparentBackground,
      }) async {
        throw const FormatException('PRIVATE_FILENAME');
      },
    );
    final config = GetIt.I<PayloadConfig>();
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 1;
    final source = img.Image(width: 8, height: 8, numChannels: 3);
    config.i2iConfig.setImage(Uint8List.fromList(img.encodePng(source)));
    config.noteI2iImported(replacing: false);

    viewmodel.runSingleGeneration();
    await waitForCurrentCommand(tester, viewmodel);

    expect(api.requests, isEmpty);
    final failed = diagnosticEvents.last;
    expect(failed.stage, GenerationPerformanceStage.failed);
    expect(failed.errorClass, 'local_preparation');
    expect(jsonEncode(failed.toJson()), isNot(contains('PRIVATE_FILENAME')));
    viewmodel.dispose();
  });

  testWidgets('ordinary I2I publishes busy state before heavy preparation', (
    tester,
  ) async {
    final barrierEntered = Completer<void>();
    final releaseBarrier = Completer<void>();
    var prepareCalls = 0;
    final outputImage = img.Image(width: 8, height: 8, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
      preparationFeedbackBarrier: () async {
        if (!barrierEntered.isCompleted) barrierEntered.complete();
        await releaseBarrier.future;
      },
      prepareI2iBatch: ({
        required config,
        required targetWidth,
        required targetHeight,
        required transparentBackground,
      }) async {
        prepareCalls++;
        final plan = I2iRequestPlan(
          imageB64: base64Encode(config.imageBytes!),
          maskB64: null,
          width: targetWidth,
          height: targetHeight,
          strength: config.strength,
          noise: config.noise,
          addOriginalImage: false,
          composite: null,
          summary: 'test img2img',
        );
        return I2iRequestBatch(
          plans: [plan],
          serial: true,
          summary: plan.summary,
        );
      },
    );
    final config = GetIt.I<PayloadConfig>();
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 1;
    config.i2iConfig.setImage(Uint8List.fromList(img.encodePng(outputImage)));
    config.noteI2iImported(replacing: false);

    viewmodel.startGeneration();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(
      () => barrierEntered.future.timeout(const Duration(seconds: 5)),
    );

    expect(viewmodel.currentCommand?.isExecuting.value, isTrue);
    expect(prepareCalls, 0);

    releaseBarrier.complete();
    await waitForCurrentCommand(tester, viewmodel);
    expect(prepareCalls, 1);
    viewmodel.stopGeneration();
    await tester.pumpAndSettle();
    viewmodel.dispose();
  });

  test('Vibe encoding is cached by model and Information Extracted', () async {
    final fake = _FakeEncodeVibeUseCase();
    final viewmodel = GenerationPageViewmodel(encodeVibeUseCase: fake);
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-4-5-full';
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
    config.paramConfig.model = 'nai-diffusion-4-5-full';
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
    config.paramConfig.model = 'nai-diffusion-4-5-full';
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
    config.paramConfig.model = 'nai-diffusion-4-5-full';
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

  test('manual size input rejects values outside the generation boundary', () {
    final viewmodel = GenerationPageViewmodel();
    final paramConfig = GetIt.I<PayloadConfig>().paramConfig;
    final initialSizes = List<GenerationSize>.of(paramConfig.sizes);

    expect(viewmodel.addManualSize('0', '1024').isValid, isFalse);
    expect(viewmodel.addManualSize('-64', '1024').isValid, isFalse);
    expect(viewmodel.addManualSize('2048', '2048').isValid, isFalse);
    expect(
      viewmodel.addManualSize('999999999999999999999999', '64').isValid,
      isFalse,
    );
    expect(paramConfig.sizes, initialSizes);
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

  testWidgets('stopping waits for the in-flight request before finishing', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _BlockingApiService();
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
    );
    final commandStatus = GetIt.I<CommandStatus>();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 2
      ..generationIntervalSec = 0;

    viewmodel.startGeneration();
    await tester.pump(const Duration(milliseconds: 1));
    expect(api.calls, 1);

    viewmodel.stopGeneration();
    await tester.pump();

    expect(commandStatus.isGenerationActive.value, isTrue);
    expect(commandStatus.isStopping.value, isTrue);
    expect(commandStatus.isWaitingForNextGeneration.value, isFalse);
    expect(api.calls, 1);

    api.response.complete(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    ));
    await waitForCurrentCommand(tester, viewmodel);

    expect(commandStatus.isGenerationActive.value, isFalse);
    expect(commandStatus.isStopping.value, isFalse);
    expect(api.calls, 1);
    expect(viewmodel.commandList.single.value.imageBytes, isNotNull);
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
    settings.parallelApiEnabled = true;
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'A', token: 'pst-a'),
      ApiTokenConfig(label: 'B', token: 'pst-b'),
      ApiTokenConfig(label: 'C', token: 'pst-c'),
    ]);

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0, 1, 2, 3]);
    expect(viewmodel.commandList, hasLength(4));
    viewmodel.stopGeneration();
    await tester.pump();
    viewmodel.dispose();
  });

  testWidgets('one Takoma token fans out one prompt with consecutive seeds', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _WaitingFanoutApiService(
      4,
      ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(outputImage)),
        ]),
      ),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
    );
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..updatePrimaryApiKey('takoma-fanout-token')
      ..parallelApiEnabled = true
      ..generationCount = 4
      ..generationIntervalSec = 0
      ..debugApiEnabled = false
      // Takoma forwards image_format and returns the official WebP.
      ..imageSaveFormat = GeneratedImageSaveFormat.webp;
    config.settings.apiTokens
      ..clear()
      ..add(ApiTokenConfig(
        label: 'Takoma',
        token: 'takoma-fanout-token',
        isPrimary: true,
        apiBaseUrl: 'https://api.takoma.app',
        concurrency: 4,
      ));

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 500 && viewmodel.commandStatus.isGenerationActive.value;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();

    expect(api.requests, hasLength(4));
    expect(
      api.requests.map((request) => request.endpoint),
      everyElement('https://api.takoma.app/ai/generate-image'),
    );
    expect(
      api.requests.map((request) => request.headers['authorization']),
      everyElement('Bearer takoma-fanout-token'),
    );
    final seeds = api.requests
        .map((request) =>
            (request.payload['parameters'] as Map<String, dynamic>)['seed'])
        .cast<int>()
        .toList()
      ..sort();
    final prompts =
        api.requests.map((request) => request.payload['input']).toSet();
    expect(seeds, hasLength(4));
    expect(seeds[1] - seeds[0], 1);
    expect(seeds[2] - seeds[1], 1);
    expect(seeds[3] - seeds[2], 1);
    expect(prompts, hasLength(1));
    expect(
      api.requests.map(
          (request) => (request.payload['parameters'] as Map)['image_format']),
      everyElement('webp'),
    );
    expect(
      viewmodel.commandList
          .where((command) => command.value.imageBytes != null),
      hasLength(4),
    );
    viewmodel.dispose();
  });

  testWidgets('Takoma concurrency one keeps a single worker', (tester) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..parallelApiEnabled = true
      ..generationCount = 4
      ..generationIntervalSec = 0
      ..debugApiEnabled = false;
    config.settings.apiTokens
      ..clear()
      ..add(ApiTokenConfig(
        label: 'Takoma',
        token: 'takoma-single-token',
        isPrimary: true,
        apiBaseUrl: 'https://api.takoma.app',
        concurrency: 1,
      ));

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0]);
    expect(viewmodel.createdTasks, [1]);
    viewmodel.stopGeneration();
    viewmodel.dispose();
  });

  testWidgets(
      'mixed official and Takoma accounts use one official plus four Takoma workers',
      (tester) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _WaitingFanoutApiService(
      5,
      ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(outputImage)),
        ]),
      ),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
    );
    final config = GetIt.I<PayloadConfig>()
      ..promptMode = PromptMode.random
      ..rootPromptConfig = PromptConfig(
        selectionMethod: 'single_sequential',
        strs: ['prompt-a', 'prompt-b', 'prompt-c', 'prompt-d', 'prompt-e'],
        prompts: [],
      );
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..parallelApiEnabled = true
      ..generationCount = 5
      ..generationIntervalSec = 0
      ..debugApiEnabled = false;
    config.settings.apiTokens
      ..clear()
      ..add(ApiTokenConfig(
        label: 'Takoma',
        token: 'takoma-mixed-token',
        isPrimary: true,
        apiBaseUrl: 'https://api.takoma.app',
        concurrency: 4,
      ))
      ..add(ApiTokenConfig(
        label: 'NovelAI',
        token: 'official-mixed-token',
        apiBaseUrl: 'https://api.novelai.net',
        concurrency: 1,
      ));

    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 500 && viewmodel.commandStatus.isGenerationActive.value;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();

    expect(api.requests, hasLength(5));
    final takomaRequests = api.requests
        .where((request) =>
            request.headers['authorization'] == 'Bearer takoma-mixed-token')
        .toList();
    final officialRequests = api.requests
        .where((request) =>
            request.headers['authorization'] == 'Bearer official-mixed-token')
        .toList();
    expect(takomaRequests, hasLength(4));
    expect(officialRequests, hasLength(1));
    expect(
      takomaRequests.map((request) => request.endpoint),
      everyElement('https://api.takoma.app/ai/generate-image'),
    );
    expect(
      officialRequests.single.endpoint,
      'https://api.novelai.net/ai/generate-image',
    );
    expect(
      api.requests.map((request) => request.payload['input']).toSet(),
      {'prompt-a', 'prompt-b', 'prompt-c', 'prompt-d', 'prompt-e'},
    );
    viewmodel.dispose();
  });

  testWidgets('per-account concurrency limits the shared worker pool',
      (tester) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-5-full';
    config.settings
      ..parallelApiEnabled = true
      ..generationCount = 5
      ..generationIntervalSec = 0
      ..debugApiEnabled = false;
    config.settings.apiTokens
      ..clear()
      ..add(ApiTokenConfig(
        label: 'Takoma',
        token: 'takoma-limited-token',
        isPrimary: true,
        apiBaseUrl: 'https://api.takoma.app',
        concurrency: 2,
      ))
      ..add(ApiTokenConfig(
        label: 'NovelAI',
        token: 'official-limited-token',
        apiBaseUrl: 'https://api.novelai.net',
        concurrency: 1,
      ));

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0, 1, 2]);
    expect(viewmodel.createdTasks, [1, 2, 3]);
    expect(viewmodel.commandList, hasLength(3));
    viewmodel.stopGeneration();
    viewmodel.dispose();
  });

  testWidgets('parallel second-wave cards show logical task numbers 6 to 10', (
    tester,
  ) async {
    final outputImage = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FirstSuccessThenBlockingApiService(
      directorResponseZip([
        Uint8List.fromList(img.encodePng(outputImage)),
      ]),
    );
    final viewmodel = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
    );
    final settings = GetIt.I<PayloadConfig>().settings;
    settings
      ..debugApiEnabled = true
      ..generationCount = 40
      ..generationIntervalSec = 0
      ..generationPageColumnCount = 5
      ..resultDisplayMode = 'classic'
      ..parallelApiEnabled = true
      ..apiTokens.addAll([
        ApiTokenConfig(label: 'A', token: 'pst-a'),
        ApiTokenConfig(label: 'B', token: 'pst-b'),
        ApiTokenConfig(label: 'C', token: 'pst-c'),
        ApiTokenConfig(label: 'D', token: 'pst-d'),
      ]);

    viewmodel.startGeneration();
    for (var attempt = 0; attempt < 100 && api.calls < 10; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(api.calls, 10);
    expect(viewmodel.commandStatus.currentGenerationCount, 5);

    await tester.binding.setSurfaceSize(const Size(2200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requestingCommands = viewmodel.commandList.reversed.take(5).toList();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GridView.count(
          crossAxisCount: 5,
          children: [
            for (final command in requestingCommands)
              ClassicInfoCard(command: command),
          ],
        ),
      ),
    ));
    await tester.pump();

    for (var taskNumber = 6; taskNumber <= 10; taskNumber++) {
      expect(
        find.text('Requesting $taskNumber/40 ...'),
        findsOneWidget,
      );
    }
    expect(find.text('Requesting 5/40 ...'), findsNothing);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GridView.count(
          crossAxisCount: 5,
          children: [
            for (final command in requestingCommands)
              InfoCard(command: command),
          ],
        ),
      ),
    ));
    await tester.pump();
    for (var taskNumber = 6; taskNumber <= 10; taskNumber++) {
      expect(
        find.text('Requesting $taskNumber/40 ...'),
        findsOneWidget,
      );
    }
    expect(find.text('Requesting 5/40 ...'), findsNothing);

    viewmodel.stopGeneration();
    api.blockedResponse.complete(ApiResponse(
      status: '500',
      data: Uint8List.fromList(utf8.encode('{"message":"stopped"}')),
    ));
    await tester.pumpAndSettle();
    viewmodel.dispose();
  });

  testWidgets('disabled tokens do not get workers', (tester) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.parallelApiEnabled = true;
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'A', token: 'pst-a'),
      ApiTokenConfig(label: 'B', token: 'pst-b', enabled: false),
      ApiTokenConfig(label: 'C', token: 'pst-c'),
    ]);

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0, 1, 2]);
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
    settings.parallelApiEnabled = true;
    settings.apiTokens.addAll([
      ApiTokenConfig(label: 'A', token: 'pst-a'),
      ApiTokenConfig(label: 'B', token: 'pst-b'),
      ApiTokenConfig(label: 'C', token: 'pst-c'),
    ]);

    viewmodel.startGeneration();

    expect(viewmodel.createdWorkers, [0, 1]);
    expect(viewmodel.createdTasks, [1, 2]);
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

  testWidgets('runSingleGeneration ignores an active batch tool', (
    tester,
  ) async {
    final viewmodel = _WorkerRecordingViewmodel();
    final config = GetIt.I<PayloadConfig>();
    const plan = I2iRequestPlan(
      imageB64: 'aW1hZ2U=',
      maskB64: null,
      width: 1216,
      height: 832,
      strength: 0.5,
      noise: 0,
      addOriginalImage: false,
      composite: null,
      summary: 'Enhance batch tool',
    );
    config.activateBatchTool(BatchToolSnapshot.enhance(
      enhanceBatch: const I2iRequestBatch(
        plans: [plan],
        serial: true,
        summary: 'Enhance batch tool',
      ),
      parameters: ParamConfig(model: 'nai-diffusion-5-full'),
      upscale: false,
      outputWidth: 1216,
      outputHeight: 832,
    ));

    viewmodel.runSingleGeneration();

    expect(viewmodel.lastToolSnapshot, isNull);
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
  testWidgets('locked single candidate repeat batch dispatches five tasks',
      (tester) async {
    final config = GetIt.I<PayloadConfig>();
    config.rootPromptConfig = PromptConfig(
        type: 'config',
        selectionMethod: 'all',
        shuffled: false,
        strs: [],
        prompts: [
          PromptConfig(selectionMethod: 'single', strs: ['R'], prompts: []),
          PromptConfig(
              selectionMethod: 'single_sequential',
              strs: ['C1', 'C2', 'C3', 'C4', 'C5'],
              prompts: []),
          PromptConfig(
              selectionMethod: 'single_sequential',
              num: 17,
              strs: ['A'],
              prompts: []),
        ]);
    final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)))
        ])));
    final viewmodel = GenerationPageViewmodel(
        apiService: api,
        fileService: _RecordingFileService(),
        accountService: _FakeAccountService());
    addTearDown(viewmodel.dispose);
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 85
      ..generationIntervalSec = 0
      ..lockToAllCombinations = true;
    viewmodel.startGeneration();
    for (var attempt = 0;
        attempt < 500 && viewmodel.commandStatus.isGenerationActive.value;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
    expect(config.settings.generationCount, 5);
    expect(viewmodel.commandStatus.isGenerationActive.value, isFalse);
    expect(api.calls, 5);
    expect(api.requests.map((r) => r.payload['input']).toList(),
        List.generate(5, (i) => 'R, C${i + 1}, A'));
  });

  testWidgets(
      'one-off paid action skips a primary account that disallows points',
      (tester) async {
    final image = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(image)),
      ]),
    ));
    final config = GetIt.I<PayloadConfig>();
    config.settings
      ..updatePrimaryApiKey('pst-blocked')
      ..apiTokens.first.allowPoints = false
      ..apiTokens.add(ApiTokenConfig(label: 'Ready', token: 'pst-ready'))
      ..parallelApiEnabled = true
      ..debugApiEnabled = false;
    final vm = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
    );
    addTearDown(vm.dispose);

    vm.runSingleGeneration();
    await waitForCurrentCommand(tester, vm);

    expect(api.calls, 1);
    expect(api.requests.single.headers['authorization'], 'Bearer pst-ready');
    expect(vm.currentCommand?.value.imageBytes, isNotNull);
  });

  testWidgets('parallel-off generation uses the only enabled listed account',
      (tester) async {
    final image = img.Image(width: 64, height: 64, numChannels: 3);
    final api = _FakeApiService(ApiResponse(
      status: '200',
      data: directorResponseZip([
        Uint8List.fromList(img.encodePng(image)),
      ]),
    ));
    final config = GetIt.I<PayloadConfig>();
    config.settings
      ..updatePrimaryApiKey('pst-main')
      ..parallelApiEnabled = false
      ..generationCount = 1
      ..generationIntervalSec = 0
      ..debugApiEnabled = true;
    config.settings.apiTokens.first.enabled = false;
    config.settings.apiTokens.add(ApiTokenConfig(
      label: 'Selected',
      token: 'pst-selected',
      enabled: true,
    ));
    final vm = GenerationPageViewmodel(
      apiService: api,
      fileService: _RecordingFileService(),
    );
    addTearDown(vm.dispose);

    vm.runSingleGeneration();
    await waitForCurrentCommand(tester, vm);

    expect(api.calls, 1);
    expect(api.requests.single.headers['authorization'], 'Bearer pst-selected');
  });

  for (final remember in [true, false]) {
    testWidgets(
        'locked full cycle with parallel APIs starts a fresh complete batch remember=$remember',
        (tester) async {
      final config = GetIt.I<PayloadConfig>();
      config.rootPromptConfig =
          PromptConfig(strs: ['__A__ + __A__'], prompts: [], shuffled: false);
      config.savedPromptConfigList = [
        PromptConfig(
            comment: 'A',
            selectionMethod: 'single_sequential',
            strs: ['A1', 'A2', 'A3', 'A4', 'A5', 'A6'],
            prompts: [])
      ];
      final generate = GeneratePayloadUseCase(payloadConfig: config);
      generate();
      generate();
      final api = _FakeApiService(ApiResponse(
          status: '200',
          data: directorResponseZip([
            Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 64)))
          ])));
      final viewmodel = GenerationPageViewmodel(
          apiService: api,
          fileService: _RecordingFileService(),
          accountService: _FakeAccountService());
      addTearDown(viewmodel.dispose);
      config.settings
        ..debugApiEnabled = true
        ..generationCount = 999
        ..generationIntervalSec = 0
        ..lockToAllCombinations = true
        ..rememberSequentialProgress = remember
        ..parallelApiEnabled = true
        ..apiTokens
            .add(ApiTokenConfig(label: 'Second', token: 'local-test-second'));
      expect(viewmodel.totalCombinations, 6);
      viewmodel.startGeneration();
      for (var attempt = 0;
          attempt < 500 && viewmodel.commandStatus.isGenerationActive.value;
          attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(config.settings.generationCount, 6);
      expect(viewmodel.commandStatus.isGenerationActive.value, isFalse);
      expect(api.calls, 6);
      expect(
          api.requests.map((r) => r.payload['input']).toList(),
          remember
              ? [
                  'A3 + A3',
                  'A4 + A4',
                  'A5 + A5',
                  'A6 + A6',
                  'A1 + A1',
                  'A2 + A2'
                ]
              : [
                  'A1 + A1',
                  'A2 + A2',
                  'A3 + A3',
                  'A4 + A4',
                  'A5 + A5',
                  'A6 + A6'
                ]);
      expect(api.requests.map((r) => r.headers['authorization']).toSet(),
          hasLength(2));
      viewmodel.startGeneration();
      for (var attempt = 0;
          attempt < 500 && viewmodel.commandStatus.isGenerationActive.value;
          attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(api.calls, 12);
      expect(config.settings.generationCount, 6);
      expect(api.requests.skip(6).map((r) => r.payload['input']),
          api.requests.take(6).map((r) => r.payload['input']));
    });

    testWidgets('token with allowPoints=false blocks request when cost > 0',
        (tester) async {
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([Uint8List(0)]),
      ));
      final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: _RecordingFileService(),
        preparationFeedbackBarrier: () async {},
      );
      final config = GetIt.I<PayloadConfig>();
      config.settings.debugApiEnabled = false;
      config.settings.apiTokens.first.allowPoints = false;
      config.paramConfig
        ..model = 'nai-diffusion-4-5-curated'
        ..steps = 50;

      vm.runSingleGeneration();
      for (var i = 0;
          i < 100 && (vm.currentCommand?.isExecuting.value ?? true);
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(api.calls, 0);
      expect(
        vm.currentCommand?.value.info,
        anyOf(
          contains('This account is configured not to spend Anlas points'),
          contains('api_token_points_blocked_error'),
        ),
      );
      vm.dispose();
    });

    testWidgets(
        'insufficient points reassign a single task to another enabled account',
        (tester) async {
      final image = img.Image(width: 64, height: 64, numChannels: 3);
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(image)),
        ]),
      ));
      final accounts = _FixedPerTokenAccountService(const {
        'pst-empty': SubscriptionInfo(anlas: 0, tier: 1, active: true),
        'pst-ready': SubscriptionInfo(anlas: 100, tier: 1, active: true),
      });
      final config = GetIt.I<PayloadConfig>();
      config.settings
        ..updatePrimaryApiKey('pst-empty')
        ..apiTokens.add(ApiTokenConfig(label: 'Ready', token: 'pst-ready'))
        ..parallelApiEnabled = true
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..debugApiEnabled = false;
      final vm = GenerationPageViewmodel(
        apiService: api,
        accountService: accounts,
        fileService: _RecordingFileService(),
      );
      addTearDown(vm.dispose);

      vm.startGeneration();
      for (var i = 0;
          i < 500 && vm.commandStatus.isGenerationActive.value;
          i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump(const Duration(seconds: 1));

      expect(api.calls, 1);
      expect(api.requests.single.headers['authorization'], 'Bearer pst-ready');
      expect(vm.commandList.single.value.imageBytes, isNotNull);
    });

    testWidgets(
        'startGeneration excludes allowPoints=false accounts from paid generation',
        (tester) async {
      final image = img.Image(width: 64, height: 64, numChannels: 3);
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(image)),
        ]),
      ));
      final accounts = _FixedPerTokenAccountService(const {
        'pst-blocked': SubscriptionInfo(anlas: 100, tier: 1, active: true),
        'pst-allowed': SubscriptionInfo(anlas: 100, tier: 1, active: true),
      });
      final config = GetIt.I<PayloadConfig>();
      config.paramConfig
        ..model = 'nai-diffusion-4-5-curated'
        ..steps = 50;
      config.settings
        ..updatePrimaryApiKey('pst-blocked')
        ..apiTokens.first.allowPoints = false
        ..apiTokens.add(ApiTokenConfig(
            label: 'Allowed', token: 'pst-allowed', allowPoints: true))
        ..parallelApiEnabled = true
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..debugApiEnabled = false;
      final vm = GenerationPageViewmodel(
        apiService: api,
        accountService: accounts,
        fileService: _RecordingFileService(),
      );
      addTearDown(vm.dispose);

      vm.startGeneration();
      for (var i = 0;
          i < 500 && vm.commandStatus.isGenerationActive.value;
          i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump(const Duration(seconds: 1));

      expect(api.calls, 1);
      expect(
          api.requests.single.headers['authorization'], 'Bearer pst-allowed');
      expect(vm.commandList, hasLength(1));
      expect(vm.commandList.single.value.imageBytes, isNotNull);
    });

    testWidgets('Takoma accounts refuse mask inpainting before sending', (
      tester,
    ) async {
      final api =
          _FakeApiService(ApiResponse(status: '200', data: Uint8List(0)));
      final config = GetIt.I<PayloadConfig>();
      final source = img.Image(width: 64, height: 64, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(20, 100, 180, 255));
      final mask = img.Image(width: 64, height: 64, numChannels: 3);
      img.fill(mask, color: img.ColorRgb8(255, 255, 255));
      config.paramConfig.model = 'nai-diffusion-5-full';
      config.i2iConfig
        ..setImage(Uint8List.fromList(img.encodePng(source)))
        ..setMask(Uint8List.fromList(img.encodePng(mask)), []);
      config.i2iEnabled = true;
      config.settings
        ..debugApiEnabled = false
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..updatePrimaryApiKey('takoma-inpaint-token');
      config.settings.apiTokens
        ..clear()
        ..add(ApiTokenConfig(
          label: 'Takoma',
          token: 'takoma-inpaint-token',
          isPrimary: true,
          apiBaseUrl: 'https://api.takoma.app',
        ));
      final prepared = await tester.runAsync(() =>
          PrepareI2iRequestUseCase(config: config.i2iConfig)
              .planBatch(targetWidth: 64, targetHeight: 64));
      final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: _RecordingFileService(),
        preparationFeedbackBarrier: _skipPreparationFeedbackBarrier,
        prepareI2iBatch: (
                {required config,
                required targetWidth,
                required targetHeight,
                required transparentBackground}) async =>
            prepared!,
      );

      vm.startGeneration();
      await waitForCurrentCommand(tester, vm);

      expect(api.calls, 0);
      expect(vm.commandList, hasLength(1));
      expect(vm.commandList.single.value.imageBytes, isNull);
      expect(
        vm.commandList.single.value.info,
        anyOf(
          contains('Takoma API'),
          contains('takoma_unsupported_feature_error'),
        ),
      );
      vm.dispose();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
        'startGeneration emits a single error card when all accounts disallow points for paid generation',
        (tester) async {
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([Uint8List(0)]),
      ));
      final config = GetIt.I<PayloadConfig>();
      config.paramConfig
        ..model = 'nai-diffusion-4-5-curated'
        ..steps = 50;
      config.settings
        ..updatePrimaryApiKey('pst-blocked-1')
        ..apiTokens.first.allowPoints = false
        ..apiTokens.add(ApiTokenConfig(
            label: 'Blocked 2', token: 'pst-blocked-2', allowPoints: false))
        ..parallelApiEnabled = true
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..debugApiEnabled = false;
      final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: _RecordingFileService(),
      );
      addTearDown(vm.dispose);

      vm.startGeneration();
      await waitForCurrentCommand(tester, vm);

      expect(api.calls, 0);
      expect(vm.commandList, hasLength(1));
      expect(vm.commandList.single.value.imageBytes, isNull);
      expect(
        vm.commandList.single.value.info,
        anyOf(
          contains('This account is configured not to spend Anlas points'),
          contains('api_token_points_blocked_error'),
        ),
      );
    });

    testWidgets(
        'startGeneration excludes allowFree=false accounts from free generation',
        (tester) async {
      final image = img.Image(width: 64, height: 64, numChannels: 3);
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([
          Uint8List.fromList(img.encodePng(image)),
        ]),
      ));
      final accounts = _FixedPerTokenAccountService(const {
        'pst-nofree': SubscriptionInfo(anlas: 100, tier: 3, active: true),
        'pst-free': SubscriptionInfo(anlas: 100, tier: 3, active: true),
      });
      final config = GetIt.I<PayloadConfig>();
      config.paramConfig
        ..model = 'nai-diffusion-4-5-curated'
        ..sizes = [const GenerationSize(width: 832, height: 1216)]
        ..steps = 28;
      config.settings
        ..updatePrimaryApiKey('pst-nofree')
        ..subscriptionTier = 3
        ..subscriptionActive = true
        ..apiTokens.first.allowFree = false
        ..apiTokens.add(ApiTokenConfig(
            label: 'FreeAllowed', token: 'pst-free', allowFree: true))
        ..parallelApiEnabled = true
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..debugApiEnabled = false;
      final vm = GenerationPageViewmodel(
        apiService: api,
        accountService: accounts,
        fileService: _RecordingFileService(),
      );
      addTearDown(vm.dispose);

      vm.startGeneration();
      for (var i = 0;
          i < 500 && vm.commandStatus.isGenerationActive.value;
          i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump(const Duration(seconds: 1));

      expect(api.calls, 1);
      expect(api.requests.single.headers['authorization'], 'Bearer pst-free');
      expect(vm.commandList, hasLength(1));
      expect(vm.commandList.single.value.imageBytes, isNotNull);
    });

    testWidgets(
        'startGeneration emits a single error card when all accounts disallow free quota for free generation',
        (tester) async {
      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([Uint8List(0)]),
      ));
      final config = GetIt.I<PayloadConfig>();
      config.paramConfig
        ..model = 'nai-diffusion-4-5-curated'
        ..sizes = [const GenerationSize(width: 832, height: 1216)]
        ..steps = 28;
      config.settings
        ..updatePrimaryApiKey('pst-nofree-1')
        ..subscriptionTier = 3
        ..subscriptionActive = true
        ..apiTokens.first.allowFree = false
        ..apiTokens.add(ApiTokenConfig(
            label: 'NoFree 2', token: 'pst-nofree-2', allowFree: false))
        ..parallelApiEnabled = true
        ..generationCount = 1
        ..generationIntervalSec = 0
        ..debugApiEnabled = false;
      final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: _RecordingFileService(),
      );
      addTearDown(vm.dispose);

      vm.startGeneration();
      await waitForCurrentCommand(tester, vm);

      expect(api.calls, 0);
      expect(vm.commandList, hasLength(1));
      expect(vm.commandList.single.value.imageBytes, isNull);
      expect(
        vm.commandList.single.value.info,
        anyOf(
          contains('This account is configured not to use free Opus quota'),
          contains('api_token_free_blocked_error'),
        ),
      );
    });

    testWidgets(
        'inpaint with composite outputs finished image size in additionalInfo',
        (tester) async {
      final base = img.Image(width: 256, height: 256, numChannels: 4);
      img.fill(base, color: img.ColorRgba8(100, 100, 100, 255));
      final baseBytes = Uint8List.fromList(img.encodePng(base));

      final config = GetIt.I<PayloadConfig>();
      config.settings.debugApiEnabled = true;
      config.i2iEnabled = true;
      final mask = img.Image(width: 256, height: 256, numChannels: 4);
      img.fillRect(mask,
          x1: 96,
          y1: 96,
          x2: 160,
          y2: 160,
          color: img.ColorRgba8(255, 255, 255, 255));
      config.i2iConfig
        ..setImage(baseBytes)
        ..setMask(Uint8List.fromList(img.encodePng(mask)), [])
        ..setManualFocusFrame(const CropRect(x: 32, y: 32, w: 128, h: 128));
      config.noteI2iImported(replacing: false);

      final prepared = await tester.runAsync(() =>
          PrepareI2iRequestUseCase(config: config.i2iConfig)
              .planBatch(targetWidth: 256, targetHeight: 256));
      final plan = prepared!.plans.first;
      final infill =
          img.Image(width: plan.width, height: plan.height, numChannels: 4);
      img.fill(infill, color: img.ColorRgba8(200, 200, 200, 255));
      final infillBytes = Uint8List.fromList(img.encodePng(infill));

      final api = _FakeApiService(ApiResponse(
        status: '200',
        data: directorResponseZip([infillBytes]),
      ));
      final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: _RecordingFileService(),
        preparationFeedbackBarrier: () async {},
        prepareI2iBatch: (
                {required config,
                required targetWidth,
                required targetHeight,
                required transparentBackground}) async =>
            prepared,
      );

      vm.runSingleGeneration();
      for (var i = 0;
          i < 500 && (vm.currentCommand?.isExecuting.value ?? true);
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(api.calls, 1);
      final additional = vm.currentCommand?.value.additionalInfo;
      expect(additional, isNotNull);
      expect(additional!['width'], 256);
      expect(additional['height'], 256);
      expect(additional['inpaint_request_width'], isNotNull);
      expect(additional['inpaint_request_height'], isNotNull);
      vm.dispose();
    });
  }
}
