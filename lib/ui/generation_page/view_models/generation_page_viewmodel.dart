import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/generation_performance_diagnostics.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:lorem_ipsum/lorem_ipsum.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/data/use_cases/encode_vibe_use_case.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_director_tool_request_use_case.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_scheduler.dart';

const infoCardContentListLength = 200;
const _opusUsageRefreshResultThreshold = 5;
const _balanceSettlementRetryDelays = [
  Duration(milliseconds: 300),
  Duration(seconds: 1),
  Duration(seconds: 2),
];

typedef PreparationFeedbackBarrier = Future<void> Function();
typedef I2iBatchPreparer = Future<I2iRequestBatch?> Function({
  required I2IConfig config,
  required int targetWidth,
  required int targetHeight,
  required bool transparentBackground,
});

Future<void> _defaultPreparationFeedbackBarrier() async {
  final binding = WidgetsBinding.instance;
  if (!binding.hasScheduledFrame) binding.scheduleFrame();
  await binding.endOfFrame;
}

Future<I2iRequestBatch?> _defaultI2iBatchPreparer({
  required I2IConfig config,
  required int targetWidth,
  required int targetHeight,
  required bool transparentBackground,
}) {
  return PrepareI2iRequestUseCase(
    config: config,
    transparentBackground: transparentBackground,
  ).planBatch(
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );
}

bool _usesTransparentI2iBackground(ParamConfig config) {
  return config.model.contains('diffusion-5') &&
      config.toJson()['transparent_background'] == true;
}

GeneratedImageStoragePolicy _storagePolicySnapshot(Settings settings) {
  final supportsDesktopJpeg = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);
  final outputDirectory = settings.outputFolderPath;
  if (!supportsDesktopJpeg ||
      !settings.jpegStorageEnabled ||
      outputDirectory.trim().isEmpty) {
    return GeneratedImageStoragePolicy.pngOnly(
      outputDirectory: outputDirectory,
    );
  }
  return GeneratedImageStoragePolicy(
    jpegEnabled: true,
    retainOriginalPng: settings.retainOriginalPng,
    pngOutputDirectory: outputDirectory,
    jpegOutputDirectory: outputDirectory,
  );
}

/// Per-worker generation state. Worker 0 is the legacy single-token path;
/// additional workers exist only while multiple API tokens are enabled.
class _WorkerState {
  Timer? intervalTimer;
  Command<void, InfoCardContent>? command;
  GenerationLease? lease;
  int consecutiveFailures = 0;
  bool paused = false;
}

class _LogicalGenerationTask {
  PayloadGenerationResult? cachedPayloadResult;
  I2iRequestBatch? cachedI2iBatch;
  String? cachedRetryFingerprint;
  GenerationDiagnosticContext? diagnosticContext;
  Command<void, InfoCardContent>? cardCommand;
}

class _BatchAccounting {
  _BatchAccounting(this.tokens, {required this.reconcileBalances});

  final List<String> tokens;
  final bool reconcileBalances;
  final Map<String, int> startingBalances = {};
  final Map<String, int> estimatedTotals = {};
  final Map<String, int> successCounts = {};
  final Map<String, int> sentRequests = {};
  final Map<String, Command<void, InfoCardContent>> lastCommands = {};
  final Map<String, int> lastSuccessfulTaskNumbers = {};
  final Map<String, Future<void>> baselineFutures = {};
  final Map<String, List<Command<void, InfoCardContent>>>
      pendingOpusUsageCommands = {};
  final Map<String, Future<void>> opusUsageRefreshes = {};
  final Map<String, int> resultsSinceOpusUsageRefresh = {};
  int activeRequests = 0;
  bool stopped = false;
  Future<void>? finalization;
}

class GenerationPageViewmodel extends ChangeNotifier {
  final EncodeVibeUseCase _encodeVibeUseCase;
  final ApiService _apiService;
  final AccountService _accountService;
  final FileService _fileService;
  final GeneratedImageStorage _generatedImageStorage;
  final ImageService _imageService;
  final PrepareDirectorToolRequestUseCase _prepareDirectorToolRequest;
  final PreparationFeedbackBarrier _preparationFeedbackBarrier;
  final I2iBatchPreparer _prepareI2iBatch;
  final Map<String, Future<String>> _vibeEncodingFutures = {};

  GenerationPageViewmodel({
    EncodeVibeUseCase? encodeVibeUseCase,
    ApiService? apiService,
    AccountService? accountService,
    FileService? fileService,
    GeneratedImageStorage? generatedImageStorage,
    ImageService? imageService,
    PrepareDirectorToolRequestUseCase? prepareDirectorToolRequest,
    PreparationFeedbackBarrier? preparationFeedbackBarrier,
    I2iBatchPreparer? prepareI2iBatch,
  })  : _encodeVibeUseCase = encodeVibeUseCase ??
            EncodeVibeUseCase(apiService: apiService ?? ApiService.shared),
        _apiService = apiService ?? ApiService.shared,
        _accountService = accountService ??
            AccountService(apiService: apiService ?? ApiService.shared),
        _fileService = fileService ?? FileService(),
        _generatedImageStorage = generatedImageStorage ??
            GeneratedImageStorageService(fileService: fileService),
        _imageService = imageService ?? ImageService(),
        _prepareDirectorToolRequest = prepareDirectorToolRequest ??
            const PrepareDirectorToolRequestUseCase(),
        _preparationFeedbackBarrier =
            preparationFeedbackBarrier ?? _defaultPreparationFeedbackBarrier,
        _prepareI2iBatch = prepareI2iBatch ?? _defaultI2iBatchPreparer;

  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  CommandStatus get commandStatus => GetIt.I<CommandStatus>();
  List<Command<void, InfoCardContent>> get commandList =>
      commandStatus.commandList;
  int get colNum => payloadConfig.settings.generationPageColumnCount;

  Command<void, InfoCardContent>? currentCommand;
  Command<void, InfoCardContent>? lastEnhanceCommand;
  Command<void, InfoCardContent>? lastDirectorCommand;

  bool _isPreparingEnhance = false;
  bool get isPreparingEnhance => _isPreparingEnhance;
  bool _isPreparingDirector = false;
  bool get isPreparingDirector => _isPreparingDirector;
  Object? _enhancePreparationError;
  Object? _directorPreparationError;

  Object? takeEnhancePreparationError() {
    final error = _enhancePreparationError;
    _enhancePreparationError = null;
    return error;
  }

  Object? takeDirectorPreparationError() {
    final error = _directorPreparationError;
    _directorPreparationError = null;
    return error;
  }

  PayloadGenerationResult? _cachedPayloadResult;
  I2iRequestBatch? _cachedI2iBatch;
  String? _cachedRetryFingerprint;
  GenerationDiagnosticContext? _cachedDiagnosticContext;
  int _primaryConsecutiveFailures = 0;
  bool _primaryWorkerPaused = false;
  Timer? _generationIntervalTimer;

  /// Tokens captured at generation start; index-aligned with workers.
  List<String> _activeTokens = [];
  List<String> _activeTokenLabels = [];
  final Map<int, _WorkerState> _extraWorkers = {};
  final Map<int, _LogicalGenerationTask> _logicalTasks = {};
  GenerationScheduler? _scheduler;
  GenerationLease? _primaryLease;
  _BatchAccounting? _activeBatch;

  /// Last known Anlas balance per token (updated after each generation).
  final Map<String, int> _lastAnlasBalances = {};
  final Map<String, DateTime> _lastAnlasBalanceTimes = {};
  final Map<String, SubscriptionInfo> _subscriptionSnapshots = {};
  final Map<String, DateTime> _subscriptionSnapshotTimes = {};
  Map<String, int> get lastAnlasBalances => Map.of(_lastAnlasBalances);

  /// Estimated Anlas for the next generation, shown on the start buttons
  /// before anything is sent. Null while unknown or still computing.
  final ValueNotifier<AnlasCost?> nextCostEstimate = ValueNotifier(null);
  String? _costEstimateKey;
  int _costEstimateEpoch = 0;
  bool _subscriptionRefreshInFlight = false;
  DateTime? _lastSubscriptionRefreshAttempt;

  /// True when the estimate is an upper bound (several sizes configured, one
  /// picked at random per request — the estimate uses the most expensive).
  bool get nextCostIsUpperBound =>
      payloadConfig.paramConfig.sizes.length > 1 &&
      !(payloadConfig.i2iEnabled && payloadConfig.i2iConfig.hasImage);

  /// Whether SMEA multipliers apply to the current model (V4/V5 drop the
  /// sm flags from the payload entirely).
  bool get _smActive =>
      !payloadConfig.paramConfig.model.contains('diffusion-4') &&
      !payloadConfig.paramConfig.model.contains('diffusion-5');

  int get _pendingVibeEncodingAnlas {
    final config = payloadConfig;
    final model = config.paramConfig.model;
    if (!config.vibeEnabled || !model.contains('-4-')) return 0;
    if (config.preciseReferenceEnabled && model.contains('-4-5-')) return 0;
    final pendingCount = config.vibeConfigListV4
        .where((vibe) => vibe.canEncode && vibe.encodingFor(model) == null)
        .length;
    return pendingCount * 2;
  }

  /// Recomputes [nextCostEstimate] when any relevant input changed. Cheap to
  /// call from build methods: a fingerprint short-circuits repeats, and the
  /// img2img planning that needs image decoding runs asynchronously.
  void refreshCostEstimate() {
    refreshSubscriptionSnapshot();
    final paramConfig = payloadConfig.paramConfig;
    final i2i = payloadConfig.i2iConfig;
    final sizes = payloadConfig.i2iEnabled && i2i.hasImage
        ? [i2i.requestSize]
        : paramConfig.sizes;
    if (sizes.isEmpty) return;
    if (!payloadConfig.settings.subscriptionStatusKnown) {
      nextCostEstimate.value = null;
      return;
    }
    final sm = _smActive && paramConfig.sm;
    final smDyn = _smActive && paramConfig.smDyn;
    final key = [
      payloadConfig.i2iEnabled && i2i.hasImage,
      i2i.planRevision,
      i2i.strength,
      sizes.map((size) => '${size.width}x${size.height}').join(','),
      paramConfig.steps,
      sm,
      smDyn,
      paramConfig.model,
      payloadConfig.settings.subscriptionTier,
      payloadConfig.settings.subscriptionActive,
      payloadConfig.settings.opusUsageAvailable,
      payloadConfig.preciseReferenceEnabled
          ? payloadConfig.preciseReferenceConfigList
              .where((reference) => reference.enabled)
              .length
          : 0,
      payloadConfig.vibeEnabled ? payloadConfig.vibeConfigListV4.length : 0,
      _pendingVibeEncodingAnlas,
      paramConfig.nSamples,
    ].join('|');
    if (key == _costEstimateKey) return;
    _costEstimateKey = key;
    final epoch = ++_costEstimateEpoch;
    Future<void>.microtask(() {
      if (epoch == _costEstimateEpoch) _computeCostEstimate(epoch);
    });
  }

  Future<void> _computeCostEstimate(int epoch) async {
    final paramConfig = payloadConfig.paramConfig;
    final i2i = payloadConfig.i2iConfig;
    final tier = payloadConfig.settings.subscriptionTier;
    final subscriptionActive = payloadConfig.settings.subscriptionActive;
    final primaryToken = payloadConfig.settings.effectiveApiTokens.firstOrNull;
    final usage = primaryToken == null
        ? null
        : _freshSubscriptionSnapshot(primaryToken.token)?.usage;
    final opusUsageAvailable = usage == null
        ? payloadConfig.settings.opusUsageAvailable == true
        : !usage.isNegative;
    final sm = _smActive && paramConfig.sm;
    final smDyn = _smActive && paramConfig.smDyn;
    final supportsReferences = !paramConfig.model.contains('diffusion-5');
    final preciseCount =
        supportsReferences && payloadConfig.preciseReferenceEnabled
            ? payloadConfig.preciseReferenceConfigList
                .where((reference) => reference.enabled)
                .length
            : 0;
    final vibeCount = supportsReferences && payloadConfig.vibeEnabled
        ? payloadConfig.vibeConfigListV4.length
        : 0;
    final vibeEncodingAnlas = _pendingVibeEncodingAnlas;
    // With several sizes one is picked at random per request; estimate the
    // most expensive so the display is an honest upper bound.
    final useI2i = payloadConfig.i2iEnabled && i2i.hasImage;
    final sizes = useI2i ? [i2i.requestSize] : paramConfig.sizes;
    var largest = sizes.first;
    for (final size in sizes) {
      if (size.width * size.height > largest.width * largest.height) {
        largest = size;
      }
    }

    AnlasCost? estimate;
    try {
      if (!useI2i) {
        estimate = estimateAnlasCost(
          width: largest.width,
          height: largest.height,
          steps: paramConfig.steps,
          sm: sm,
          smDyn: smDyn,
          tier: tier,
          subscriptionActive: subscriptionActive,
          model: paramConfig.model,
          opusUsageAvailable: opusUsageAvailable,
          nSamples: paramConfig.nSamples,
          preciseReferenceCount: preciseCount,
          vibeCount: vibeCount,
        );
      } else {
        final batch = await _prepareI2iBatch(
          config: i2i,
          targetWidth: largest.width,
          targetHeight: largest.height,
          transparentBackground: _usesTransparentI2iBackground(paramConfig),
        );
        if (batch != null) {
          final base = estimateBatchAnlasCost(
            tiles: batch.plans
                .map((plan) => (width: plan.width, height: plan.height))
                .toList(),
            steps: paramConfig.steps,
            action: batch.plans.first.isInpaint ? 'infill' : 'img2img',
            strength: i2i.strength,
            sm: sm,
            smDyn: smDyn,
            tier: tier,
            subscriptionActive: subscriptionActive,
            model: paramConfig.model,
            opusUsageAvailable: opusUsageAvailable,
            nSamples: paramConfig.nSamples,
          );
          // Precise references and extra vibes are billed per request, so a
          // split mask pays them once per tile.
          final extraPerRequest = (preciseCount * preciseReferenceAnlas +
                  max(0, vibeCount - freeVibeCount) * extraVibeAnlas) *
              paramConfig.nSamples;
          estimate = AnlasCost(
            anlas: base.anlas + extraPerRequest * batch.plans.length,
            isFreeUnderOpus: base.isFreeUnderOpus && extraPerRequest == 0,
            perImageAnlas: base.perImageAnlas,
          );
        }
      }
    } catch (_) {
      estimate = null;
    }
    if (estimate != null && vibeEncodingAnlas > 0) {
      estimate = AnlasCost(
        anlas: estimate.anlas + vibeEncodingAnlas,
        isFreeUnderOpus: false,
        perImageAnlas: estimate.perImageAnlas,
      );
    }
    if (epoch != _costEstimateEpoch) return;
    nextCostEstimate.value = estimate;
  }

  /// Refreshes the active account used for the pre-generation price display.
  /// Calls within one minute are coalesced. Generation uses this cached
  /// snapshot for pricing and never waits for an account query before sending.
  Future<void> refreshSubscriptionSnapshot() async {
    if (_subscriptionRefreshInFlight) return;
    final settings = payloadConfig.settings;
    if (settings.debugApiEnabled) {
      settings.subscriptionTier = 0;
      settings.subscriptionActive = false;
      settings.subscriptionStatusKnown = true;
      settings.opusUsageAvailable = false;
      return;
    }
    final now = DateTime.now();
    final lastAttempt = _lastSubscriptionRefreshAttempt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(minutes: 1)) {
      return;
    }
    final tokens = settings.effectiveApiTokens;
    if (tokens.isEmpty ||
        tokens.first.token.isEmpty ||
        tokens.first.token == 'pst-abcd') {
      settings.subscriptionTier = 0;
      settings.subscriptionActive = false;
      settings.subscriptionStatusKnown = true;
      settings.opusUsageAvailable = false;
      return;
    }
    _subscriptionRefreshInFlight = true;
    _lastSubscriptionRefreshAttempt = now;
    final info = await _accountService.fetchSubscription(
      token: tokens.first.token,
      proxy: settings.proxy,
    );
    _subscriptionRefreshInFlight = false;
    if (info == null) {
      settings.subscriptionStatusKnown = false;
    } else {
      _recordSubscriptionInfo(tokens.first.token, info);
    }
    _costEstimateKey = null;
    notifyListeners();
  }

  void _recordSubscriptionInfo(String token, SubscriptionInfo info) {
    final settings = payloadConfig.settings;
    final now = DateTime.now();
    _subscriptionSnapshots[token] = info;
    _subscriptionSnapshotTimes[token] = now;
    final displayToken = settings.effectiveApiTokens.firstOrNull?.token;
    if (token == displayToken) {
      settings.subscriptionTier = info.tier;
      settings.subscriptionActive = info.active;
      settings.subscriptionStatusKnown = true;
      settings.opusUsageAvailable =
          info.usage == null ? null : !info.usage!.isNegative;
    }
    if (info.anlas != null) {
      _lastAnlasBalances[token] = info.anlas!;
      _lastAnlasBalanceTimes[token] = now;
    }
  }

  void setCardsPerCol(int value) {
    payloadConfig.settings.generationPageColumnCount = value;
    notifyListeners();
  }

  void setResultDisplayMode(String value) {
    payloadConfig.settings.resultDisplayMode = value;
    notifyListeners();
  }

  void promptModeChanged() {
    _costEstimateKey = null;
    notifyListeners();
  }

  void advancedFeaturesChanged() {
    _costEstimateKey = null;
    notifyListeners();
  }

  void setRandomSeedEnabled(bool? value) {
    if (value == null) return;
    payloadConfig.paramConfig.randomSeed = value;
    notifyListeners();
  }

  void setSeed(String value) {
    final normalizedValue = value.trim();
    if (normalizedValue.isEmpty) {
      payloadConfig.paramConfig.seed = null;
      notifyListeners();
      return;
    }
    final parseResult = int.tryParse(normalizedValue);
    if (parseResult == null) return;
    payloadConfig.paramConfig.seed = parseResult;
    notifyListeners();
  }

  void removeSize(GenerationSize size) {
    final sizes = payloadConfig.paramConfig.sizes;
    if (sizes.length == 1) return;
    payloadConfig.paramConfig.sizes = List.of(sizes)..remove(size);
    notifyListeners();
  }

  void addSize(GenerationSize size) {
    final sizes = payloadConfig.paramConfig.sizes;
    if (sizes.contains(size)) return;
    payloadConfig.paramConfig.sizes = List.of(sizes)..add(size);
    notifyListeners();
  }

  void addManualSize(String width, String height) {
    var parsedWidth = int.tryParse(width);
    var parsedHeight = int.tryParse(height);
    if (parsedWidth == null || parsedHeight == null) return;
    parsedWidth = (parsedWidth / 64).ceil() * 64;
    parsedHeight = (parsedHeight / 64).ceil() * 64;
    addSize(GenerationSize(width: parsedWidth, height: parsedHeight));
  }

  void setGenerationInterval(String value) {
    final parseResult = int.tryParse(value);
    if (parseResult == null || parseResult < 0) return;
    payloadConfig.settings.generationIntervalSec = parseResult;
    notifyListeners();
  }

  bool get lockToAllCombinations =>
      payloadConfig.settings.lockToAllCombinations;

  int get totalCombinations => payloadConfig.totalCombinations;

  void setLockToAllCombinations(bool value) {
    payloadConfig.settings.lockToAllCombinations = value;
    if (value) {
      setGenerationCount(totalCombinations.toString());
    } else if (GetIt.I.isRegistered<ConfigService>()) {
      GetIt.I<ConfigService>().saveConfig(payloadConfig.toJson());
    }
    notifyListeners();
  }

  void setGenerationCount(String value) {
    final parseResult = int.tryParse(value);
    if (parseResult == null || parseResult < 0) return;
    payloadConfig.settings.generationCount = parseResult;
    if (GetIt.I.isRegistered<ConfigService>()) {
      GetIt.I<ConfigService>().saveConfig(payloadConfig.toJson());
    }
    notifyListeners();
  }

  void addAndRunCommand(Command<void, InfoCardContent> command) {
    // Make sure list is not longer than expected
    while (commandList.length >= infoCardContentListLength) {
      commandStatus.removeProgress(commandList.removeAt(0));
    }
    // Push command into list and run command
    commandList.add(command);
    notifyListeners();
    command();
  }

  void addLoremInfoCardContent() async {
    // Async command as image requires loading
    commandFunc() async {
      await Future.delayed(const Duration(milliseconds: 500));
      final random = Random();
      final bytes = Uint8List.sublistView(
        await rootBundle.load('assets/appicon.png'),
      );
      return InfoCardContent(
        title:
            '#${commandList.length}: ${loremIpsum(words: random.nextInt(3) + 3, initWithLorem: true)}',
        info: loremIpsum(words: random.nextInt(300), initWithLorem: true),
        additionalInfo: {"Random Seed": random.nextInt(1 << 31)},
        imageBytes: random.nextInt(2) == 1 ? null : bytes,
      );
    }

    // Skip if active command exists
    if (currentCommand != null && currentCommand!.isExecuting.value) return;
    final command = Command.createAsyncNoParam(
      commandFunc,
      initialValue: InfoCardContent.fromEmpty(),
    );
    currentCommand = command;
    addAndRunCommand(command);
  }

  String _tokenForWorker(int workerIndex) {
    if (workerIndex < _activeTokens.length) return _activeTokens[workerIndex];
    return payloadConfig.settings.apiKey;
  }

  /// Runs a split-mask inpaint: every focus tile is requested and composited
  /// onto the same canvas. Overlapping tiles run one after another so each
  /// sees the previous result; non-overlapping grid tiles run concurrently,
  /// capped like the reference implementation.
  Future<Uint8List> _runSplitInpaint({
    required I2iRequestBatch batch,
    required PayloadGenerationResult basePayloadResult,
    required Future<Uint8List> Function(Map<String, dynamic>) sendPlan,
  }) async {
    const maxTileConcurrency = 4;
    final useCase = PrepareI2iRequestUseCase(config: payloadConfig.i2iConfig);
    final canvas = useCase.newCompositeCanvas(
      baseImageB64: batch.compositeBaseImageB64,
    );
    Uint8List? lastResponse;
    if (batch.serial) {
      for (final (index, plan) in batch.plans.indexed) {
        final requestPlan = index == 0
            ? plan
            : useCase.rebaseFocusPlanOnCanvas(canvas: canvas, plan: plan);
        final payload = GeneratePayloadUseCase.applyI2iPlanToPayload(
          basePayloadResult.payload,
          requestPlan,
        );
        final response = await sendPlan(payload);
        useCase.blendInpaintTileInto(
          canvas: canvas,
          responseBytes: response,
          plan: plan,
        );
        lastResponse = response;
      }
    } else {
      // Freeze all non-overlapping requests before the first await. They share
      // prompt/model/reference/seed semantics and can safely run concurrently.
      final payloads = batch.plans
          .map(
            (plan) => GeneratePayloadUseCase.applyI2iPlanToPayload(
              basePayloadResult.payload,
              plan,
            ),
          )
          .toList(growable: false);
      for (var start = 0;
          start < batch.plans.length;
          start += maxTileConcurrency) {
        final slice = batch.plans.skip(start).take(maxTileConcurrency).toList();
        final payloadSlice = payloads.skip(start).take(maxTileConcurrency);
        final responses = await Future.wait(
          payloadSlice.map(sendPlan),
        );
        for (final (index, response) in responses.indexed) {
          useCase.blendInpaintTileInto(
            canvas: canvas,
            responseBytes: response,
            plan: slice[index],
          );
          lastResponse = response;
        }
      }
    }

    return useCase.finishComposite(
      canvas: canvas,
      responseBytes: lastResponse ?? Uint8List(0),
    );
  }

  String? _tokenLabelForWorker(int workerIndex) {
    if (_activeTokens.length <= 1) return null;
    if (workerIndex < _activeTokenLabels.length) {
      return _activeTokenLabels[workerIndex];
    }
    return null;
  }

  /// Builds the actual generation command for one attempt. Overridable in
  /// tests to avoid network access.
  ///
  /// [presetBatch] bypasses the Img2Img config entirely and sends the given
  /// request batch instead — used by Enhance, whose source image lives in its
  /// own config.
  @visibleForTesting
  Command<void, InfoCardContent> createGenerationCommand({
    required int workerIndex,
    I2iRequestBatch? presetBatch,
    int? seedOverride,
    String promptSuffix = '',
  }) {
    final batchAccounting = _activeBatch;
    final token = _tokenForWorker(workerIndex);
    final scheduledLease = _leaseForWorker(workerIndex);
    final acceptedSettings = payloadConfig.settings;
    final storagePolicy = _storagePolicySnapshot(acceptedSettings);
    final metadataPolicy = GeneratedImageMetadataPolicy(
      eraseMetadata: acceptedSettings.metadataEraseEnabled,
      customMetadataEnabled: acceptedSettings.customMetadataEnabled,
      customMetadataContent: acceptedSettings.customMetadataContent,
    );
    int? startingBalance;
    DateTime? startingBalanceTime;
    var vibeExtractionAnlas = 0;
    late final Command<void, InfoCardContent> command;

    commandFunc() async {
      final settings = payloadConfig.settings;
      final endpoint = settings.debugApiEnabled
          ? settings.debugApiPath
          : 'https://image.novelai.net/ai/generate-image';
      startingBalance = _lastAnlasBalances[token];
      startingBalanceTime = _lastAnlasBalanceTimes[token];
      batchAccounting?.activeRequests++;

      PayloadGenerationResult? payloadResult;
      I2iRequestBatch? i2iBatch;
      GenerationDiagnosticContext? diagnosticContext;
      try {
        vibeExtractionAnlas = await ensureVibeEncodings(
          token: token,
          endpoint: settings.debugApiEnabled
              ? EncodeVibeUseCase.endpointForDebugGenerationPath(endpoint)
              : EncodeVibeUseCase.officialEndpoint,
        );

        // Retry the exact random prompt/seed only while every input that can
        // affect the request is still compatible with the cached payload.
        // A failed request must never pin a removed/replaced reference image,
        // I2I plan, model, prompt, seed, or generation parameter for later runs.
        if (presetBatch != null) {
          i2iBatch = presetBatch;
          payloadResult = GeneratePayloadUseCase(
            payloadConfig: payloadConfig,
            i2iPlan: i2iBatch.plans.first,
            seedOverride: seedOverride,
            promptSuffix: promptSuffix,
            applyPlainI2iCompatibilityFields: false,
          )();
        } else {
          final currentFingerprint = _generationRetryFingerprint();
          final cachedPayload = _getCachedPayload(workerIndex);
          final canReuseCache = cachedPayload != null &&
              _getCachedRetryFingerprint(workerIndex) == currentFingerprint;
          if (canReuseCache) {
            payloadResult = cachedPayload;
            i2iBatch = _getCachedBatch(workerIndex);
            diagnosticContext = _getCachedDiagnosticContext(workerIndex);
          } else {
            if (cachedPayload != null) {
              _setCachedPayload(workerIndex, null, null);
            }

            // I2I preparation may yield. If the user edits its image, mask,
            // frame, size, or any other request input meanwhile, discard that
            // obsolete plan and prepare again from the newest state.
            while (true) {
              vibeExtractionAnlas += await ensureVibeEncodings(
                token: token,
                endpoint: settings.debugApiEnabled
                    ? EncodeVibeUseCase.endpointForDebugGenerationPath(endpoint)
                    : EncodeVibeUseCase.officialEndpoint,
              );
              final buildFingerprint = _generationRetryFingerprint();
              i2iBatch = null;
              final preparationStopwatch = Stopwatch()..start();
              final i2iConfig = payloadConfig.i2iConfig;
              final correlationId = payloadConfig.i2iEnabled &&
                      i2iConfig.hasImage &&
                      _apiService.diagnosticsEnabled
                  ? _apiService.createDiagnosticCorrelationId()
                  : null;
              if (correlationId != null) {
                _apiService.recordDiagnostic(GenerationPerformanceEvent(
                  correlationId: correlationId,
                  stage: GenerationPerformanceStage.preparationStarted,
                ));
              }
              if (payloadConfig.i2iEnabled && i2iConfig.hasImage) {
                final target = i2iConfig.requestSize;
                try {
                  await _preparationFeedbackBarrier();
                  i2iBatch = await _prepareI2iBatch(
                    config: i2iConfig,
                    targetWidth: target.width,
                    targetHeight: target.height,
                    transparentBackground: _usesTransparentI2iBackground(
                      payloadConfig.paramConfig,
                    ),
                  );
                } catch (_) {
                  preparationStopwatch.stop();
                  if (correlationId != null) {
                    _apiService.recordDiagnostic(GenerationPerformanceEvent(
                      correlationId: correlationId,
                      stage: GenerationPerformanceStage.failed,
                      elapsedMicroseconds:
                          preparationStopwatch.elapsedMicroseconds,
                      errorClass: 'local_preparation',
                    ));
                  }
                  rethrow;
                }
              }
              preparationStopwatch.stop();
              if (buildFingerprint != _generationRetryFingerprint()) {
                continue;
              }
              payloadResult = GeneratePayloadUseCase(
                payloadConfig: payloadConfig,
                i2iPlan: i2iBatch?.plans.first,
              )();
              if (buildFingerprint != _generationRetryFingerprint()) {
                continue;
              }
              diagnosticContext = i2iBatch == null
                  ? null
                  : _newDiagnosticContext(
                      correlationId: correlationId,
                      preparationMicroseconds:
                          preparationStopwatch.elapsedMicroseconds,
                      batch: i2iBatch,
                    );
              if (diagnosticContext != null) {
                _apiService.recordDiagnostic(GenerationPerformanceEvent(
                  correlationId: diagnosticContext.correlationId,
                  stage: GenerationPerformanceStage.preparationCompleted,
                  elapsedMicroseconds:
                      diagnosticContext.preparationMicroseconds,
                  normalizedImageBytes: diagnosticContext.normalizedImageBytes,
                ));
              }
              _setCachedPayload(
                workerIndex,
                payloadResult,
                i2iBatch,
                retryFingerprint: buildFingerprint,
                diagnosticContext: diagnosticContext,
              );
              break;
            }
          }
        }
        _applyCurrentVibesToPayload(payloadResult);

        final estimatedGenerationCost = _estimateResultAnlas(
          token: token,
          payloadResult: payloadResult,
          batch: i2iBatch,
          vibeExtractionAnlas: 0,
        );
        if (!settings.debugApiEnabled &&
            _hasFreshInsufficientBalance(token, estimatedGenerationCost)) {
          throw const NovelAiApiException(
            'The freshly refreshed Anlas balance is insufficient for this '
            'estimated request.',
          );
        }

        final headers = payloadConfig.getHeadersForToken(token);
        Future<Uint8List> sendPlan(Map<String, dynamic> payload) async {
          batchAccounting?.sentRequests.update(
            token,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
          final response = await _apiService.fetchData(
            ApiRequest(
              endpoint: endpoint,
              proxy: settings.proxy,
              headers: headers,
              payload: payload,
              diagnosticContext: diagnosticContext,
            ),
          );
          final data = ApiService.requireSuccessfulData(
            response,
            operation: 'generate the image',
          );
          final processingStopwatch = Stopwatch()..start();
          if (diagnosticContext != null) {
            _apiService.recordDiagnostic(GenerationPerformanceEvent(
              correlationId: diagnosticContext.correlationId,
              stage: GenerationPerformanceStage.resultProcessingStarted,
            ));
          }
          try {
            final processed = _imageService.processResponse(data);
            processingStopwatch.stop();
            if (diagnosticContext != null) {
              _apiService.recordDiagnostic(GenerationPerformanceEvent(
                correlationId: diagnosticContext.correlationId,
                stage: GenerationPerformanceStage.resultProcessingCompleted,
                elapsedMicroseconds: processingStopwatch.elapsedMicroseconds,
              ));
            }
            return processed;
          } catch (_) {
            processingStopwatch.stop();
            if (diagnosticContext != null) {
              _apiService.recordDiagnostic(GenerationPerformanceEvent(
                correlationId: diagnosticContext.correlationId,
                stage: GenerationPerformanceStage.failed,
                elapsedMicroseconds: processingStopwatch.elapsedMicroseconds,
                errorClass: 'result_processing',
              ));
            }
            rethrow;
          }
        }

        Uint8List imageBytes;
        if (i2iBatch != null && i2iBatch.isSplit) {
          imageBytes = await _runSplitInpaint(
            batch: i2iBatch,
            basePayloadResult: payloadResult,
            sendPlan: sendPlan,
          );
        } else {
          imageBytes = await sendPlan(payloadResult.payload);
          // NovelAI returns raw infill pixels. Match the official frontend by
          // blending every infill response locally with its feathered mask.
          final plan = i2iBatch?.plans.first;
          if (plan?.isInpaint == true) {
            imageBytes = await PrepareI2iRequestUseCase(
              config: payloadConfig.i2iConfig,
            ).compositeInpaintResponse(
              responseBytes: imageBytes,
              plan: plan!,
              compositeBaseImageB64: i2iBatch?.compositeBaseImageB64,
            );
          }
        }
        // Add custom metadata
        if (metadataPolicy.eraseMetadata) {
          final metadataString = metadataPolicy.customMetadataEnabled
              ? metadataPolicy.customMetadataContent
              : '';
          imageBytes = await _imageService.embedMetadata(
            imageBytes,
            metadataString,
          );
        }
        if (scheduledLease != null &&
            _scheduler?.reserveSuccess(scheduledLease) != true) {
          return InfoCardContent.fromEmpty();
        }
        // Save image
        final filePrefix = payloadResult.suggestedFileName.isNotEmpty
            ? _getSafeFileName(payloadResult.suggestedFileName)
            : '';
        final fileName = [
          if (filePrefix.isNotEmpty) filePrefix,
          _fileService.generateTimestampString(
            commandStatus.generationTimestamp,
          ),
          (scheduledLease?.taskNumber ?? commandStatus.currentGenerationCount)
              .toString()
              .padLeft(6, '0'),
          '${_fileService.generateRandomString()}.png',
        ].join('-');
        final storageSubmission = _generatedImageStorage.submit(
          GeneratedImageStorageRequest(
            logicalTaskId: scheduledLease == null
                ? 'generation:${commandStatus.currentGenerationCount}:'
                    '${commandStatus.generationTimestamp.microsecondsSinceEpoch}'
                : 'generation:${scheduledLease.taskNumber}:'
                    '${commandStatus.generationTimestamp.microsecondsSinceEpoch}',
            pngBytes: imageBytes,
            fileName: fileName,
            storagePolicy: storagePolicy,
            metadataPolicy: metadataPolicy,
          ),
        );
        final estimatedCost = _estimateResultAnlas(
          token: token,
          payloadResult: payloadResult,
          batch: i2iBatch,
          vibeExtractionAnlas: vibeExtractionAnlas,
        );
        final model = payloadResult.payload['model']?.toString() ?? '';
        final opusPreview = _opusPreviewFor(token: token, model: model);
        final settleOpusUsage = _shouldSettleOpusUsage(
          token: token,
          model: model,
          debugApiEnabled: settings.debugApiEnabled,
        );
        final previewContent = InfoCardContent(
          title: fileName,
          info: payloadResult.comment,
          additionalInfo: digestPayloadResult(payloadResult),
          imageArtifact: storageSubmission.artifact,
          anlasCost: estimatedCost,
          anlasCostIsEstimated: true,
          tokenLabel: _tokenLabelForWorker(workerIndex),
          opusUsage: opusPreview,
          opusUsageIsEstimated: settleOpusUsage,
          opusUsageSettling: settleOpusUsage,
        );
        command.value = previewContent;
        if (scheduledLease != null) {
          final card = _logicalTasks[scheduledLease.taskNumber]?.cardCommand;
          if (card != null && !identical(card, command)) {
            card.value = previewContent;
            notifyListeners();
          }
        }
        if (scheduledLease != null) {
          if (_scheduler?.detachWorkerForPersistence(scheduledLease) != true) {
            return InfoCardContent.fromEmpty();
          }
          unawaited(_completeScheduledStorage(
            lease: scheduledLease,
            workerIndex: workerIndex,
            token: token,
            estimatedCost: estimatedCost,
            batch: batchAccounting,
            submission: storageSubmission,
          ));
          return previewContent;
        }

        final imageArtifact = await storageSubmission.completed;
        _setCachedPayload(workerIndex, null, null);
        _recordAttemptSuccess(workerIndex);
        commandStatus.currentGenerationCount++;
        return InfoCardContent(
          title: fileName,
          info: payloadResult.comment,
          additionalInfo: digestPayloadResult(payloadResult),
          imageArtifact: imageArtifact,
          anlasCost: estimatedCost,
          anlasCostIsEstimated: true,
          tokenLabel: _tokenLabelForWorker(workerIndex),
          opusUsage: opusPreview,
          opusUsageIsEstimated: settleOpusUsage,
          opusUsageSettling: settleOpusUsage,
        );
      } catch (e) {
        final scheduledFailure = scheduledLease == null
            ? null
            : _scheduler?.completeFailure(scheduledLease);
        final failureCount = scheduledFailure == null
            ? _recordAttemptFailure(workerIndex)
            : _recordScheduledFailure(workerIndex, scheduledFailure);
        final pauseNotice =
            commandStatus.isGenerationActive.value && failureCount >= 5
                ? '\nAutomatic attempts for this token will pause after five '
                    'consecutive failures. You can retry manually later.'
                : '';
        return InfoCardContent(
          title: 'Error occurred in generation process.',
          info: '${e.toString()}$pauseNotice',
          additionalInfo:
              payloadResult != null ? digestPayloadResult(payloadResult) : {},
          anlasCost: vibeExtractionAnlas == 0 ? null : vibeExtractionAnlas,
          anlasCostIsEstimated: vibeExtractionAnlas != 0,
          tokenLabel: _tokenLabelForWorker(workerIndex),
        );
      }
    }

    command = Command.createAsyncNoParam(
      commandFunc,
      initialValue: InfoCardContent.fromEmpty(),
    );
    command.isExecuting.addListener(() {
      if (command.isExecuting.value) return;
      _handleGenerationCommandFinished(
        command: command,
        token: token,
        startingBalance: startingBalance,
        startingBalanceTime: startingBalanceTime,
        batch: batchAccounting,
      );
    });
    return command;
  }

  Future<void> _completeScheduledStorage({
    required GenerationLease lease,
    required int workerIndex,
    required String token,
    required int estimatedCost,
    required _BatchAccounting? batch,
    required GeneratedImageStorageSubmission submission,
  }) async {
    try {
      await submission.completed;
      if (_scheduler?.completeSuccess(lease) != true) return;
      if (batch != null) {
        batch.estimatedTotals.update(
          token,
          (value) => value + estimatedCost,
          ifAbsent: () => estimatedCost,
        );
        batch.successCounts.update(
          token,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
      }
      final task = _logicalTasks[lease.taskNumber];
      if (task != null) {
        task.cachedPayloadResult = null;
        task.cachedI2iBatch = null;
        task.cachedRetryFingerprint = null;
        task.diagnosticContext = null;
      }
      if (batch != null && task?.cardCommand != null) {
        final previousTask = batch.lastSuccessfulTaskNumbers[token] ?? -1;
        if (lease.taskNumber >= previousTask) {
          batch.lastSuccessfulTaskNumbers[token] = lease.taskNumber;
          batch.lastCommands[token] = task!.cardCommand!;
        }
      }
      _recordAttemptSuccess(workerIndex);
      commandStatus.currentGenerationCount++;
      notifyListeners();
      _finishScheduledBatchIfNeeded();
    } catch (_) {
      final failure = _scheduler?.completeFailure(lease);
      if (failure == null) return;
      _recordScheduledFailure(workerIndex, failure);
      notifyListeners();
      if (!commandStatus.isGenerationActive.value) return;
      if (workerIndex == 0) {
        if (!(currentCommand?.isExecuting.value ?? false)) nextCommand();
      } else {
        final state = _extraWorkers[workerIndex];
        if (!(state?.command?.isExecuting.value ?? false)) {
          _nextCommandForExtraWorker(workerIndex);
        }
      }
    }
  }

  @visibleForTesting
  Command<void, InfoCardContent> createScheduledGenerationCommand({
    required int workerIndex,
    required GenerationLease lease,
  }) {
    return createGenerationCommand(workerIndex: workerIndex);
  }

  int _estimateResultAnlas({
    required String token,
    required PayloadGenerationResult payloadResult,
    required I2iRequestBatch? batch,
    required int vibeExtractionAnlas,
  }) {
    try {
      final parameters =
          payloadResult.payload['parameters'] as Map<String, dynamic>;
      final width = (parameters['width'] as num).toInt();
      final height = (parameters['height'] as num).toInt();
      final steps = (parameters['steps'] as num).toInt();
      final nSamples = (parameters['n_samples'] as num?)?.toInt() ?? 1;
      final action = payloadResult.payload['action']?.toString() ?? 'generate';
      final preciseCount =
          (parameters['director_reference_images'] as List?)?.length ?? 0;
      final vibeCount =
          (parameters['reference_image_multiple'] as List?)?.length ?? 0;
      final snapshot = _freshSubscriptionSnapshot(token);
      final tier = snapshot?.tier;
      final subscriptionActive = snapshot?.active ?? false;
      final opusUsageAvailable = snapshot?.usage?.isNegative == false;
      final model = payloadResult.payload['model']?.toString() ?? '';
      final sm = parameters['sm'] == true;
      final smDyn = parameters['sm_dyn'] == true;
      final plans = batch?.plans ?? const <I2iRequestPlan>[];
      final strength = plans.isNotEmpty
          ? plans.first.strength
          : (parameters['inpaintImg2ImgStrength'] as num?)?.toDouble() ??
              (parameters['strength'] as num?)?.toDouble() ??
              1.0;
      if (batch != null && batch.isSplit) {
        final base = estimateBatchAnlasCost(
          tiles: plans
              .map((plan) => (width: plan.width, height: plan.height))
              .toList(growable: false),
          steps: steps,
          action: action,
          strength: strength,
          sm: sm,
          smDyn: smDyn,
          tier: tier,
          subscriptionActive: subscriptionActive,
          model: model,
          opusUsageAvailable: opusUsageAvailable,
          nSamples: nSamples,
        );
        final referenceCostPerRequest = (preciseCount * preciseReferenceAnlas +
                max(0, vibeCount - freeVibeCount) * extraVibeAnlas) *
            nSamples;
        return base.anlas +
            referenceCostPerRequest * plans.length +
            vibeExtractionAnlas;
      }

      return estimateAnlasCost(
            width: width,
            height: height,
            steps: steps,
            action: action,
            nSamples: nSamples,
            strength: strength,
            sm: sm,
            smDyn: smDyn,
            tier: tier,
            subscriptionActive: subscriptionActive,
            model: model,
            opusUsageAvailable: opusUsageAvailable,
            preciseReferenceCount: preciseCount,
            vibeCount: vibeCount,
          ).anlas +
          vibeExtractionAnlas;
    } catch (_) {
      return (nextCostEstimate.value?.anlas ?? 0) + vibeExtractionAnlas;
    }
  }

  SubscriptionInfo? _freshSubscriptionSnapshot(String token) {
    final fetchedAt = _subscriptionSnapshotTimes[token];
    if (fetchedAt == null ||
        DateTime.now().difference(fetchedAt) >= const Duration(minutes: 2)) {
      return null;
    }
    return _subscriptionSnapshots[token];
  }

  OpusUsage? _opusPreviewFor({
    required String token,
    required String model,
  }) {
    if (!model.contains('diffusion-5')) return null;
    final snapshot = _freshSubscriptionSnapshot(token);
    if (snapshot == null || !snapshot.active || snapshot.tier < opusTier) {
      return null;
    }
    return snapshot.usage?.projectedAt(DateTime.now());
  }

  bool _shouldSettleOpusUsage({
    required String token,
    required String model,
    required bool debugApiEnabled,
  }) {
    if (debugApiEnabled || !model.contains('diffusion-5')) return false;
    final snapshot = _freshSubscriptionSnapshot(token);
    return snapshot == null || (snapshot.active && snapshot.tier >= opusTier);
  }

  bool _hasFreshInsufficientBalance(String token, int estimatedCost) {
    if (estimatedCost <= 0) return false;
    final snapshot = _freshSubscriptionSnapshot(token);
    final balance = snapshot?.anlas;
    return balance != null && balance < estimatedCost;
  }

  void _handleGenerationCommandFinished({
    required Command<void, InfoCardContent> command,
    required String token,
    required int? startingBalance,
    required DateTime? startingBalanceTime,
    required _BatchAccounting? batch,
  }) {
    if (batch != null) batch.activeRequests--;
    final content = command.value;
    if (content.imageBytes != null && batch != null) {
      batch.lastCommands[token] = command;
      if (content.opusUsageSettling) {
        _queueBatchOpusUsageRefresh(
          batch: batch,
          command: command,
          token: token,
        );
      }
    } else if (content.imageBytes != null &&
        !payloadConfig.settings.debugApiEnabled) {
      unawaited(_refreshSingleResultBalance(
        command: command,
        token: token,
        startingBalance: startingBalance,
        startingBalanceTime: startingBalanceTime,
      ));
    }
    if (batch?.stopped == true && batch!.reconcileBalances) {
      _tryFinalizeBatch(batch);
    }
  }

  Future<void> _refreshSingleResultBalance({
    required Command<void, InfoCardContent> command,
    required String token,
    required int? startingBalance,
    required DateTime? startingBalanceTime,
  }) async {
    final estimatedCost = command.value.anlasCost ?? 0;
    final info = await _fetchSettledSubscription(
      token: token,
      startingBalance: startingBalance,
      estimatedCost: estimatedCost,
      startingUsage: command.value.opusUsage,
      settleUsage: command.value.opusUsageSettling,
    );
    if (info == null) {
      _finishUsageSettlementWithoutSnapshot(command);
      return;
    }
    _recordSubscriptionInfo(token, info);
    final remaining = info.anlas;
    if (remaining == null) {
      _applyUsageSettlement(command, info.usage);
      return;
    }
    final baselineIsFresh = startingBalanceTime != null &&
        DateTime.now().difference(startingBalanceTime) <
            const Duration(minutes: 2);
    final exactCost = baselineIsFresh &&
            startingBalance != null &&
            startingBalance >= remaining
        ? startingBalance - remaining
        : null;
    command.value = command.value.copyWith(
      anlasCost: exactCost ?? command.value.anlasCost,
      anlasCostIsEstimated: exactCost == null,
      anlasRemaining: remaining,
      opusUsage: info.usage,
      opusUsageIsEstimated: info.usage == null,
      opusUsageSettling: false,
    );
    _applyUsageSettlement(command, info.usage);
    notifyListeners();
  }

  void _queueBatchOpusUsageRefresh({
    required _BatchAccounting batch,
    required Command<void, InfoCardContent> command,
    required String token,
  }) {
    batch.pendingOpusUsageCommands.putIfAbsent(token, () => []).add(command);
    final resultCount = (batch.resultsSinceOpusUsageRefresh[token] ?? 0) + 1;
    batch.resultsSinceOpusUsageRefresh[token] = resultCount;
    if (resultCount >= _opusUsageRefreshResultThreshold) {
      _startBatchOpusUsageRefresh(batch, token);
    }
  }

  void _startBatchOpusUsageRefresh(
    _BatchAccounting batch,
    String token,
  ) {
    if (batch.opusUsageRefreshes.containsKey(token)) return;
    final pending = batch.pendingOpusUsageCommands[token];
    if (pending == null || pending.isEmpty) return;
    final commands = List<Command<void, InfoCardContent>>.of(pending);
    pending.clear();
    batch.resultsSinceOpusUsageRefresh[token] = 0;

    late final Future<void> refresh;
    refresh = _refreshBatchOpusUsage(
      batch: batch,
      token: token,
      commands: commands,
    ).whenComplete(() {
      if (identical(batch.opusUsageRefreshes[token], refresh)) {
        batch.opusUsageRefreshes.remove(token);
      }
      if (!batch.stopped &&
          (batch.resultsSinceOpusUsageRefresh[token] ?? 0) >=
              _opusUsageRefreshResultThreshold) {
        _startBatchOpusUsageRefresh(batch, token);
      }
    });
    batch.opusUsageRefreshes[token] = refresh;
    unawaited(refresh);
  }

  Future<void> _refreshBatchOpusUsage({
    required _BatchAccounting batch,
    required String token,
    required List<Command<void, InfoCardContent>> commands,
  }) async {
    SubscriptionInfo? info;
    try {
      info = await _accountService.fetchSubscription(
        token: token,
        proxy: payloadConfig.settings.proxy,
        forceRefresh: true,
      );
    } catch (_) {
      info = null;
    }
    if (info == null) {
      batch.pendingOpusUsageCommands
          .putIfAbsent(token, () => [])
          .insertAll(0, commands);
      return;
    }
    _recordSubscriptionInfo(token, info);
    for (final command in commands) {
      _applyUsageSettlement(command, info.usage);
    }
    notifyListeners();
  }

  List<Command<void, InfoCardContent>> _takePendingOpusUsageCommands(
    _BatchAccounting batch,
    String token,
  ) {
    final commands = batch.pendingOpusUsageCommands.remove(token);
    batch.resultsSinceOpusUsageRefresh.remove(token);
    return commands ?? const <Command<void, InfoCardContent>>[];
  }

  void _settlePendingBatchOpusUsage(
    _BatchAccounting batch,
    String token,
    OpusUsage? usage,
  ) {
    for (final command in _takePendingOpusUsageCommands(batch, token)) {
      _applyUsageSettlement(command, usage);
    }
  }

  void _finishPendingBatchOpusUsageWithoutSnapshot(
    _BatchAccounting batch,
    String token,
  ) {
    for (final command in _takePendingOpusUsageCommands(batch, token)) {
      _finishUsageSettlementWithoutSnapshot(command);
    }
  }

  Future<void> _awaitBatchOpusUsageRefresh(
    _BatchAccounting batch,
    String token,
  ) async {
    final refresh = batch.opusUsageRefreshes[token];
    if (refresh != null) await refresh;
  }

  void _finishUsageSettlementWithoutSnapshot(
    Command<void, InfoCardContent> command,
  ) {
    final title = command.value.title;
    void update(Command<void, InfoCardContent> target) {
      if (target.value.title != title) return;
      target.value = target.value.copyWith(opusUsageSettling: false);
    }

    update(command);
    for (final target in commandList) {
      update(target);
    }
    notifyListeners();
  }

  void _applyUsageSettlement(
    Command<void, InfoCardContent> command,
    OpusUsage? usage,
  ) {
    final title = command.value.title;
    void update(Command<void, InfoCardContent> target) {
      if (target.value.title != title) return;
      target.value = target.value.copyWith(
        opusUsage: usage,
        opusUsageIsEstimated: usage == null,
        opusUsageSettling: false,
      );
    }

    update(command);
    for (final target in commandList) {
      update(target);
    }
  }

  Future<void> _captureBatchStartingBalance(
    _BatchAccounting batch,
    String token,
  ) async {
    final info = await _accountService.fetchSubscription(
      token: token,
      proxy: payloadConfig.settings.proxy,
      forceRefresh: true,
    );
    if (info == null) return;
    _recordSubscriptionInfo(token, info);
    final balance = info.anlas;
    if (balance != null && (batch.sentRequests[token] ?? 0) == 0) {
      batch.startingBalances[token] = balance;
    }
  }

  void _tryFinalizeBatch(_BatchAccounting batch) {
    if (!batch.stopped || batch.activeRequests != 0) return;
    final successfulTokens = batch.successCounts.entries
        .where((entry) => entry.value > 0)
        .map((entry) => entry.key);
    if (successfulTokens
        .any((token) => !batch.lastCommands.containsKey(token))) {
      return;
    }
    batch.finalization ??= _finalizeBatchBalances(batch);
  }

  Future<SubscriptionInfo?> _fetchSettledSubscription({
    required String token,
    required int? startingBalance,
    required int estimatedCost,
    OpusUsage? startingUsage,
    bool settleUsage = false,
  }) async {
    SubscriptionInfo? lastUsableInfo;
    final shouldRetry =
        startingBalance != null || (settleUsage && startingUsage != null);
    final retryDelays =
        !shouldRetry ? const <Duration>[] : _balanceSettlementRetryDelays;
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelays[attempt - 1]);
      final info = await _accountService.fetchSubscription(
        token: token,
        proxy: payloadConfig.settings.proxy,
        forceRefresh: true,
      );
      if (info == null) continue;
      lastUsableInfo = info;
      final remaining = info.anlas;
      final usage = info.usage;
      final balanceMayStillBeStale = estimatedCost > 0 &&
          startingBalance != null &&
          remaining == startingBalance;
      final usageMayStillBeStale = settleUsage &&
          startingUsage != null &&
          usage != null &&
          usage.isNegative == startingUsage.isNegative &&
          (usage.percent - startingUsage.percent).abs() < 0.0001;
      final mayStillBeStale = balanceMayStillBeStale || usageMayStillBeStale;
      if (!mayStillBeStale || attempt == retryDelays.length) return info;
    }
    return lastUsableInfo;
  }

  Future<void> _finalizeBatchBalances(_BatchAccounting batch) async {
    await Future.wait(batch.tokens.map(
      (token) => _finalizeBatchToken(batch, token),
    ));
  }

  Future<void> _finalizeBatchToken(
    _BatchAccounting batch,
    String token,
  ) async {
    await batch.baselineFutures[token];
    await _awaitBatchOpusUsageRefresh(batch, token);
    final command = batch.lastCommands[token];
    if (command == null) return;
    final starting = batch.startingBalances[token];
    final info = await _fetchSettledSubscription(
      token: token,
      startingBalance: starting,
      estimatedCost: batch.estimatedTotals[token] ?? 0,
    );
    if (info == null) {
      _finishPendingBatchOpusUsageWithoutSnapshot(batch, token);
      return;
    }
    _recordSubscriptionInfo(token, info);
    _settlePendingBatchOpusUsage(batch, token, info.usage);
    final remaining = info.anlas;
    if (remaining == null) {
      notifyListeners();
      return;
    }
    final actual =
        starting != null && starting >= remaining ? starting - remaining : null;
    final successCount = batch.successCounts[token] ?? 0;
    final showPerAccountBatchBreakdown = batch.tokens.length > 1;
    command.value = command.value.copyWith(
      anlasCost:
          !showPerAccountBatchBreakdown && actual != null && successCount == 1
              ? actual
              : command.value.anlasCost,
      anlasCostIsEstimated: showPerAccountBatchBreakdown
          ? command.value.anlasCostIsEstimated
          : !(actual != null && successCount == 1),
      anlasRemaining: remaining,
      batchAnlasCost:
          showPerAccountBatchBreakdown || successCount > 1 ? actual : null,
    );
    notifyListeners();
  }

  @visibleForTesting
  Future<int> ensureVibeEncodings({
    required String token,
    String endpoint = EncodeVibeUseCase.officialEndpoint,
  }) async {
    var extractedCount = 0;

    // Encoding yields to the event loop. The user may remove A and add B while
    // A is still being extracted, so keep preparing snapshots until the
    // *current* list is fully ready. Results remain cached only on the exact
    // Vibe object and model/information pair that started each extraction.
    while (true) {
      final config = payloadConfig;
      final model = config.paramConfig.model;
      if (!config.vibeEnabled || !model.contains('-4-')) {
        return extractedCount * 2;
      }
      // Precise Reference takes the V4.5 reference payload slot. The normal
      // setters keep the two features mutually exclusive, but this guard also
      // protects migrated or transient state from spending 2 Anlas on an
      // encoding that would not be sent.
      if (config.preciseReferenceEnabled && model.contains('-4-5-')) {
        return extractedCount * 2;
      }

      final vibes = List.of(config.vibeConfigListV4);
      for (final vibe in vibes) {
        if (vibe.encodingFor(model) != null) continue;
        final imageBytes = vibe.imageBytes;
        if (imageBytes == null || imageBytes.isEmpty) {
          throw VibeEncodingException(
            'The Vibe "${vibe.fileName}" has no encoding for $model and no '
            'original image to extract again.',
          );
        }

        final info = vibe.informationExtracted;
        final cacheKey = '${identityHashCode(vibe)}|$model|'
            '${info.toStringAsFixed(6)}';
        var future = _vibeEncodingFutures[cacheKey];
        var ownsExtraction = false;
        if (future == null) {
          ownsExtraction = true;
          future = _encodeVibeUseCase(
            imageBytes: imageBytes,
            informationExtracted: info,
            model: model,
            token: token,
            proxy: config.settings.proxy,
            endpoint: endpoint,
          );
          _vibeEncodingFutures[cacheKey] = future;
        }
        try {
          final encoding = await future;
          if (ownsExtraction) extractedCount++;
          vibe.cacheEncoding(
            model: model,
            informationExtracted: info,
            encoding: encoding,
          );
        } finally {
          if (identical(_vibeEncodingFutures[cacheKey], future)) {
            _vibeEncodingFutures.remove(cacheKey);
          }
        }
      }

      final currentConfig = payloadConfig;
      final currentModel = currentConfig.paramConfig.model;
      if (!currentConfig.vibeEnabled || !currentModel.contains('-4-')) {
        return extractedCount * 2;
      }
      if (currentConfig.preciseReferenceEnabled &&
          currentModel.contains('-4-5-')) {
        return extractedCount * 2;
      }
      if (currentConfig.vibeConfigListV4
          .every((vibe) => vibe.encodingFor(currentModel) != null)) {
        return extractedCount * 2;
      }
    }
  }

  void _applyCurrentVibesToPayload(PayloadGenerationResult result) {
    final config = payloadConfig;
    final model = config.paramConfig.model;
    if (!model.contains('-4-')) return;

    final parameters = result.payload['parameters'];
    if (parameters is! Map<String, dynamic>) return;
    // A retry may reuse a cached payload after the user changes or disables
    // Vibe settings. Clear the V4 reference arrays before applying the current
    // state so stale encodings never leak into the next request.
    parameters['reference_image_multiple'] = <String>[];
    parameters['reference_strength_multiple'] = <double>[];
    parameters['reference_information_extracted_multiple'] = <double>[];

    if (!config.vibeEnabled) return;
    if (config.preciseReferenceEnabled && model.contains('-4-5-')) return;

    final encodings = <String>[];
    final strengths = <double>[];
    final informationExtracted = <double>[];
    for (final vibe in config.vibeConfigListV4) {
      final encoding = vibe.encodingFor(model);
      if (encoding == null) {
        throw StateError('Vibe encoding is not ready for ${vibe.fileName}.');
      }
      encodings.add(encoding);
      strengths.add(vibe.referenceStrength);
      informationExtracted.add(vibe.informationExtracted);
    }
    parameters['reference_image_multiple'] = encodings;
    parameters['reference_strength_multiple'] = strengths;
    parameters['reference_information_extracted_multiple'] =
        informationExtracted;
  }

  String _generationRetryFingerprint() {
    final config = payloadConfig;
    final model = config.paramConfig.model;
    return jsonEncode({
      'prompt_mode': config.promptMode.name,
      'active_profile': config.activeProfile.toJson(),
      // The cached result also owns the prompt-derived suggested file name.
      // Rebuild it when the user's file-name template changes.
      'file_name_prefix_key': config.settings.fileNamePrefixKey,
      'i2i': {
        'enabled': config.i2iEnabled,
        'config_id': identityHashCode(config.i2iConfig),
        'revision': config.i2iConfig.revision,
      },
      'precise_reference': {
        'enabled': config.preciseReferenceEnabled,
        'items': config.preciseReferenceConfigList
            .map((item) => {
                  'config_id': identityHashCode(item),
                  'image_id': identityHashCode(item.imageB64),
                  'image_length': item.imageB64.length,
                  'enabled': item.enabled,
                  'type': item.type.name,
                  'strength': item.strength,
                  'fidelity': item.fidelity,
                })
            .toList(growable: false),
      },
      'vibe': {
        'enabled': config.vibeEnabled,
        'legacy': config.vibeConfigList
            .map((item) => {
                  'config_id': identityHashCode(item),
                  'image_id': identityHashCode(item.imageB64),
                  'image_length': item.imageB64.length,
                  'information_extracted': item.infoExtracted,
                  'strength': item.referenceStrength,
                })
            .toList(growable: false),
        'v4': config.vibeConfigListV4
            .map((item) => {
                  'config_id': identityHashCode(item),
                  'strength': item.referenceStrength,
                  'information_extracted': item.informationExtracted,
                  'encoding_id': identityHashCode(item.encodingFor(model)),
                  'encoding_length': item.encodingFor(model)?.length,
                })
            .toList(growable: false),
      },
    });
  }

  PayloadGenerationResult? _getCachedPayload(int workerIndex) {
    final task = _logicalTaskForWorker(workerIndex);
    if (task != null) return task.cachedPayloadResult;
    if (workerIndex == 0) return _cachedPayloadResult;
    return null;
  }

  String? _getCachedRetryFingerprint(int workerIndex) {
    final task = _logicalTaskForWorker(workerIndex);
    if (task != null) return task.cachedRetryFingerprint;
    if (workerIndex == 0) return _cachedRetryFingerprint;
    return null;
  }

  I2iRequestBatch? _getCachedBatch(int workerIndex) {
    final task = _logicalTaskForWorker(workerIndex);
    if (task != null) return task.cachedI2iBatch;
    if (workerIndex == 0) return _cachedI2iBatch;
    return null;
  }

  GenerationDiagnosticContext? _getCachedDiagnosticContext(int workerIndex) {
    final task = _logicalTaskForWorker(workerIndex);
    if (task != null) return task.diagnosticContext;
    if (workerIndex == 0) return _cachedDiagnosticContext;
    return null;
  }

  void _setCachedPayload(
    int workerIndex,
    PayloadGenerationResult? result,
    I2iRequestBatch? batch, {
    String? retryFingerprint,
    GenerationDiagnosticContext? diagnosticContext,
  }) {
    final task = _logicalTaskForWorker(workerIndex);
    if (task != null) {
      task.cachedPayloadResult = result;
      task.cachedI2iBatch = batch;
      task.cachedRetryFingerprint = result == null ? null : retryFingerprint;
      task.diagnosticContext = result == null ? null : diagnosticContext;
      return;
    }
    if (workerIndex == 0) {
      _cachedPayloadResult = result;
      _cachedI2iBatch = batch;
      _cachedRetryFingerprint = result == null ? null : retryFingerprint;
      _cachedDiagnosticContext = result == null ? null : diagnosticContext;
      return;
    }
  }

  GenerationDiagnosticContext? _newDiagnosticContext({
    required String? correlationId,
    required int preparationMicroseconds,
    required I2iRequestBatch batch,
  }) {
    if (correlationId == null) return null;
    return GenerationDiagnosticContext(
      correlationId: correlationId,
      preparationMicroseconds: preparationMicroseconds,
      normalizedImageBytes: batch.plans.fold<int>(
        0,
        (total, plan) => total + _decodedBase64Length(plan.imageB64),
      ),
    );
  }

  static int _decodedBase64Length(String value) {
    if (value.isEmpty) return 0;
    var padding = 0;
    if (value.endsWith('==')) {
      padding = 2;
    } else if (value.endsWith('=')) {
      padding = 1;
    }
    return (value.length * 3 ~/ 4) - padding;
  }

  _LogicalGenerationTask? _logicalTaskForWorker(int workerIndex) {
    final lease = _leaseForWorker(workerIndex);
    if (lease == null) return null;
    return _logicalTasks.putIfAbsent(
      lease.taskNumber,
      _LogicalGenerationTask.new,
    );
  }

  GenerationLease? _leaseForWorker(int workerIndex) =>
      workerIndex == 0 ? _primaryLease : _extraWorkers[workerIndex]?.lease;

  bool _prepareScheduledTaskCard(
    Command<void, InfoCardContent> command,
    GenerationLease lease,
    String token,
  ) {
    final task = _logicalTasks.putIfAbsent(
      lease.taskNumber,
      _LogicalGenerationTask.new,
    );
    final card = task.cardCommand;
    if (card == null) {
      task.cardCommand = command;
      final totalTaskCount = _scheduler?.taskCount ?? 0;
      commandStatus.setProgress(
        command,
        taskNumber: lease.taskNumber,
        totalTaskCount: totalTaskCount == 0 ? null : totalTaskCount,
      );
      return true;
    }
    command.isExecuting.addListener(() {
      if (command.isExecuting.value) return;
      final content = command.value;
      if (content.title.isEmpty && content.imageBytes == null) return;
      card.value = content;
      final batch = _activeBatch;
      if (content.imageBytes != null && batch != null) {
        batch.lastCommands[token] = card;
      }
      notifyListeners();
    });
    return false;
  }

  int _recordScheduledFailure(
    int workerIndex,
    GenerationFailureResult failure,
  ) {
    if (workerIndex == 0) {
      _primaryConsecutiveFailures = failure.consecutiveFailureCount;
      _primaryWorkerPaused = failure.workerPaused;
    } else {
      final state = _extraWorkers[workerIndex];
      state?.consecutiveFailures = failure.consecutiveFailureCount;
      state?.paused = failure.workerPaused;
    }
    return failure.consecutiveFailureCount;
  }

  void _recordAttemptSuccess(int workerIndex) {
    if (workerIndex == 0) {
      _primaryConsecutiveFailures = 0;
      _primaryWorkerPaused = false;
      return;
    }
    final state = _extraWorkers[workerIndex];
    if (state == null) return;
    state.consecutiveFailures = 0;
    state.paused = false;
  }

  int _recordAttemptFailure(int workerIndex) {
    if (workerIndex == 0) {
      _primaryConsecutiveFailures++;
      return _primaryConsecutiveFailures;
    }
    final state = _extraWorkers[workerIndex];
    if (state == null) return 0;
    state.consecutiveFailures++;
    return state.consecutiveFailures;
  }

  Duration _failureBackoff(int consecutiveFailures) {
    if (consecutiveFailures >= 2) return const Duration(seconds: 15);
    if (consecutiveFailures == 1) return const Duration(seconds: 5);
    return Duration.zero;
  }

  bool get _allWorkersPaused =>
      _primaryWorkerPaused &&
      _extraWorkers.values.every((state) => state.paused);

  void nextCommand() {
    if (!commandStatus.isGenerationActive.value) return;
    if (commandStatus.isWaitingForNextGeneration.value) return;

    // Skip if active command exists
    if (currentCommand != null && currentCommand!.isExecuting.value) return;

    final lease = _scheduler?.claim('0');
    if (_scheduler != null && lease == null) {
      _finishScheduledBatchIfNeeded();
      return;
    }
    _primaryLease = lease;
    final command = lease == null
        ? createGenerationCommand(workerIndex: 0)
        : createScheduledGenerationCommand(workerIndex: 0, lease: lease);
    final addTaskCard = lease == null ||
        _prepareScheduledTaskCard(command, lease, _tokenForWorker(0));
    command.isExecuting.addListener(() {
      notifyListeners();
      // Only update after execution
      if (command.isExecuting.value) return;

      continueAfterGenerationAttempt();
    });

    // Execute command
    currentCommand = command;
    if (addTaskCard) {
      addAndRunCommand(command);
    } else {
      command();
    }
  }

  /// Runs one Director Tool against its source image. These go to the
  /// augment-image endpoint; they are billed by pixel count, and the Opus
  /// free allowance does not apply.
  Future<bool> runDirectorTool() async {
    if (_isPreparingDirector || _isPreparingEnhance) return false;
    if (commandStatus.isGenerationActive.value) return false;
    if (currentCommand != null && currentCommand!.isExecuting.value) {
      return false;
    }
    final config = payloadConfig.directorToolConfig;
    final imageBytes = config.imageBytes;
    if (imageBytes == null) return false;

    // Capture one immutable request snapshot at the click boundary. Response
    // handling must not be reclassified if the user prepares another tool or
    // image while this request is in flight.
    final requestRevision = config.requestRevision;
    final requestParameters = config.getRequestParameters();
    final toolType = config.type;
    final toolName = config.displayName;
    final sourceWidth = config.width;
    final sourceHeight = config.height;
    final settings = payloadConfig.settings;
    final apiKey = settings.apiKey;
    final proxy = settings.proxy;
    final headers = payloadConfig.getHeadersForToken(apiKey);
    final storagePolicy = _storagePolicySnapshot(settings);
    final metadataEraseEnabled = settings.metadataEraseEnabled;
    final customMetadataEnabled = settings.customMetadataEnabled;
    final customMetadataContent = settings.customMetadataContent;
    final debugApiEnabled = settings.debugApiEnabled;
    final requestTimestamp = DateTime.now();
    commandStatus.generationTimestamp = requestTimestamp;

    _isPreparingDirector = true;
    _directorPreparationError = null;
    notifyListeners();
    late final Map<String, dynamic> payload;
    late final int requestWidth;
    late final int requestHeight;
    try {
      await _preparationFeedbackBarrier();
      final prepared = await _prepareDirectorToolRequest(
        imageBytes: imageBytes,
        width: sourceWidth,
        height: sourceHeight,
      );
      final currentConfig = payloadConfig.directorToolConfig;
      if (!identical(currentConfig, config) ||
          currentConfig.requestRevision != requestRevision ||
          commandStatus.isGenerationActive.value ||
          (currentCommand?.isExecuting.value ?? false)) {
        return false;
      }
      requestWidth = prepared.width;
      requestHeight = prepared.height;
      payload = <String, dynamic>{
        ...requestParameters,
        'width': requestWidth,
        'height': requestHeight,
        'image': prepared.imageB64,
      };
    } catch (error) {
      _directorPreparationError = error;
      return false;
    } finally {
      _isPreparingDirector = false;
      notifyListeners();
    }

    var additionalResults = const <InfoCardContent>[];
    int? startingBalance;
    DateTime? startingBalanceTime;
    commandFunc() async {
      startingBalance = _lastAnlasBalances[apiKey];
      startingBalanceTime = _lastAnlasBalanceTimes[apiKey];
      try {
        final response = await _apiService.fetchData(
          ApiRequest(
            endpoint: augmentImageEndpoint,
            proxy: proxy,
            headers: headers,
            payload: payload,
          ),
        );
        final data = ApiService.requireSuccessfulData(
          response,
          operation: 'run Director Tools',
        );
        final unpacked = _imageService.processResponseImages(data);
        const backgroundVariants = ['Masked', 'Generated', 'Blend'];
        if (toolType == 'bg-removal' &&
            unpacked.length < backgroundVariants.length) {
          throw Exception(
            'Remove Background returned ${unpacked.length} image(s); expected 3.',
          );
        }
        final responseImages = toolType == 'bg-removal'
            ? unpacked.take(backgroundVariants.length).toList(growable: false)
            : [unpacked.first];
        // The request carries the source image inline; keep it out of the card.
        final info = Map<String, dynamic>.from(payload)..remove('image');
        final estimatedCost = estimateDirectorToolAnlas(
          tool: toolType,
          width: requestWidth,
          height: requestHeight,
        );
        final results = <InfoCardContent>[];
        for (final (index, rawBytes) in responseImages.indexed) {
          var imageBytes = rawBytes;
          if (metadataEraseEnabled) {
            final metadataString =
                customMetadataEnabled ? customMetadataContent : '';
            imageBytes = await _imageService.embedMetadata(
              imageBytes,
              metadataString,
            );
          }
          final variant =
              toolType == 'bg-removal' ? backgroundVariants[index] : toolName;
          final fileName = [
            _fileService.generateTimestampString(requestTimestamp),
            commandStatus.currentGenerationCount.toString().padLeft(6, '0'),
            toolType,
            if (toolType == 'bg-removal') variant.toLowerCase(),
            '${_fileService.generateRandomString()}.png',
          ].join('-');
          final storageSubmission = _generatedImageStorage.submit(
            GeneratedImageStorageRequest(
              logicalTaskId:
                  'director:${requestTimestamp.microsecondsSinceEpoch}:'
                  '$toolType:$index',
              pngBytes: imageBytes,
              fileName: fileName,
              storagePolicy: storagePolicy,
              metadataPolicy: GeneratedImageMetadataPolicy(
                eraseMetadata: metadataEraseEnabled,
                customMetadataEnabled: customMetadataEnabled,
                customMetadataContent: customMetadataContent,
              ),
            ),
          );
          final imageArtifact = await storageSubmission.completed;
          commandStatus.currentGenerationCount++;
          final resultInfo = <String, dynamic>{
            ...info,
            if (toolType == 'bg-removal') 'background_removal_variant': variant,
          };
          final resultLabel =
              toolType == 'bg-removal' ? '$toolName · $variant' : toolName;
          results.add(InfoCardContent(
            title: fileName,
            info:
                '$resultLabel\n${resultInfo.entries.map((e) => '${e.key}: ${e.value}').join('\n')}',
            additionalInfo: resultInfo,
            imageArtifact: imageArtifact,
            // One API request produced all three variants; report its total
            // cost once instead of making every card look separately billed.
            anlasCost: index == 0 ? estimatedCost : null,
            anlasCostIsEstimated: index == 0,
          ));
        }
        additionalResults = results.skip(1).toList(growable: false);
        return results.first;
      } catch (e) {
        return InfoCardContent(
          title: 'Error occurred in Director Tools.',
          info: e.toString(),
          additionalInfo: const {},
        );
      }
    }

    final command = Command.createAsyncNoParam(
      commandFunc,
      initialValue: InfoCardContent.fromEmpty(),
    );
    var appendedAdditionalResults = false;
    command.isExecuting.addListener(() {
      notifyListeners();
      if (command.isExecuting.value || appendedAdditionalResults) return;
      appendedAdditionalResults = true;
      for (final result in additionalResults) {
        _addCompletedResult(result);
      }
      if (command.value.imageBytes != null && !debugApiEnabled) {
        unawaited(_refreshSingleResultBalance(
          command: command,
          token: apiKey,
          startingBalance: startingBalance,
          startingBalanceTime: startingBalanceTime,
        ));
      }
    });
    lastDirectorCommand = command;
    currentCommand = command;
    addAndRunCommand(command);
    return true;
  }

  void _addCompletedResult(InfoCardContent content) {
    while (commandList.length >= infoCardContentListLength) {
      commandStatus.removeProgress(commandList.removeAt(0));
    }
    commandList.add(Command.createAsyncNoParam(
      () async => content,
      initialValue: content,
    ));
    notifyListeners();
  }

  void clearDirectorResult() {
    lastDirectorCommand = null;
    notifyListeners();
  }

  /// Runs one generation outside the start/stop loop (used by the
  /// img2img page's "generate once" action).
  void runSingleGeneration() {
    if (commandStatus.isGenerationActive.value) return;
    if (currentCommand != null && currentCommand!.isExecuting.value) return;
    final paramConfig = payloadConfig.paramConfig;
    if (!paramConfig.randomSeed && paramConfig.seed == null) {
      paramConfig.seed = 0;
    }
    commandStatus.generationTimestamp = DateTime.now();
    final command = createGenerationCommand(workerIndex: 0);
    command.isExecuting.addListener(notifyListeners);
    currentCommand = command;
    addAndRunCommand(command);
  }

  /// Runs one Enhance pass: a plain img2img request built from the Enhance
  /// destination's own source image, at the preset strength/noise and the
  /// magnified size. Returns false when busy or without a source image.
  Future<bool> runEnhanceGeneration() async {
    if (_isPreparingEnhance ||
        _isPreparingDirector ||
        commandStatus.isGenerationActive.value) {
      return false;
    }
    if (currentCommand != null && currentCommand!.isExecuting.value) {
      return false;
    }
    final enhance = payloadConfig.enhanceConfig;
    final bytes = enhance.imageBytes;
    if (bytes == null) return false;
    final imageRevision = enhance.imageRevision;
    final scale = enhance.scale;
    final presetIndex = enhance.presetIndex;
    final showIndividualSettings = enhance.showIndividualSettings;
    final strength = enhance.strength;
    final noise = enhance.noise;
    final target = enhance.targetSize;
    final generationFingerprint = _enhancePreparationFingerprint();

    _isPreparingEnhance = true;
    _enhancePreparationError = null;
    notifyListeners();
    try {
      await _preparationFeedbackBarrier();
      final plan = await preparePlainImg2ImgBytesInBackground(
        imageBytes: bytes,
        sourceWidth: enhance.width,
        sourceHeight: enhance.height,
        targetWidth: target.width,
        targetHeight: target.height,
        strength: strength,
        noise: noise,
        addOriginalImage: false,
        normalizeToTarget: false,
      );
      final currentEnhance = payloadConfig.enhanceConfig;
      if (!identical(currentEnhance, enhance) ||
          !currentEnhance.hasImage ||
          currentEnhance.imageRevision != imageRevision ||
          currentEnhance.scale != scale ||
          currentEnhance.presetIndex != presetIndex ||
          currentEnhance.showIndividualSettings != showIndividualSettings ||
          currentEnhance.strength != strength ||
          currentEnhance.noise != noise ||
          currentEnhance.targetSize != target ||
          _enhancePreparationFingerprint() != generationFingerprint) {
        return false;
      }

      final random = Random.secure();
      final seed = (random.nextInt(1 << 16) << 16) | random.nextInt(1 << 16);
      commandStatus.generationTimestamp = DateTime.now();
      final command = createGenerationCommand(
        workerIndex: 0,
        presetBatch: I2iRequestBatch(
          plans: [plan],
          serial: true,
          summary: plan.summary,
        ),
        seedOverride: seed,
        promptSuffix: '-2::upscaled, blurry::,',
      );
      command.isExecuting.addListener(notifyListeners);
      lastEnhanceCommand = command;
      currentCommand = command;
      _isPreparingEnhance = false;
      addAndRunCommand(command);
      return true;
    } catch (error) {
      _enhancePreparationError = error;
      return false;
    } finally {
      if (_isPreparingEnhance) {
        _isPreparingEnhance = false;
        notifyListeners();
      }
    }
  }

  void clearEnhanceResult() {
    lastEnhanceCommand = null;
    notifyListeners();
  }

  String _enhancePreparationFingerprint() {
    final settings = payloadConfig.settings;
    return jsonEncode({
      'generation': _generationRetryFingerprint(),
      'api_key': settings.apiKey,
      'proxy': settings.proxy,
      'debug_api_enabled': settings.debugApiEnabled,
      'debug_api_path': settings.debugApiPath,
      'output_folder_path': settings.outputFolderPath,
      'metadata_erase_enabled': settings.metadataEraseEnabled,
      'custom_metadata_enabled': settings.customMetadataEnabled,
      'custom_metadata_content': settings.customMetadataContent,
    });
  }

  void _nextCommandForExtraWorker(int workerIndex) {
    if (!commandStatus.isGenerationActive.value) return;
    final state = _extraWorkers[workerIndex];
    if (state == null) return;
    if (state.command != null && state.command!.isExecuting.value) return;

    final lease = _scheduler?.claim(workerIndex.toString());
    if (_scheduler != null && lease == null) {
      _finishScheduledBatchIfNeeded();
      return;
    }
    state.lease = lease;
    final command = lease == null
        ? createGenerationCommand(workerIndex: workerIndex)
        : createScheduledGenerationCommand(
            workerIndex: workerIndex,
            lease: lease,
          );
    final addTaskCard = lease == null ||
        _prepareScheduledTaskCard(
          command,
          lease,
          _tokenForWorker(workerIndex),
        );
    command.isExecuting.addListener(() {
      notifyListeners();
      if (command.isExecuting.value) return;
      _continueExtraWorkerAfterAttempt(workerIndex);
    });
    state.command = command;
    if (addTaskCard) {
      addAndRunCommand(command);
    } else {
      command();
    }
  }

  void _continueExtraWorkerAfterAttempt(int workerIndex) {
    if (!commandStatus.isGenerationActive.value) return;

    final schedulerStatus = _scheduler?.status;
    if (schedulerStatus?.stopRequested == true) {
      if (schedulerStatus!.finished) stopGeneration();
      return;
    }

    final generationCount = payloadConfig.settings.generationCount;
    if (generationCount != 0 &&
        commandStatus.currentGenerationCount >= generationCount) {
      stopGeneration();
      return;
    }

    final state = _extraWorkers[workerIndex];
    if (state == null) return;
    if (state.consecutiveFailures >= 5) {
      state.paused = true;
      if (_allWorkersPaused) stopGeneration();
      return;
    }
    state.intervalTimer?.cancel();
    final configuredDelay = Duration(
      seconds: payloadConfig.settings.generationIntervalSec,
    );
    final backoff = _failureBackoff(state.consecutiveFailures);
    final delay =
        configuredDelay.compareTo(backoff) >= 0 ? configuredDelay : backoff;
    if (delay == Duration.zero) {
      _nextCommandForExtraWorker(workerIndex);
      return;
    }
    state.intervalTimer = Timer(delay, () {
      state.intervalTimer = null;
      _nextCommandForExtraWorker(workerIndex);
    });
  }

  void _startExtraWorkers() {
    final generationCount = payloadConfig.settings.generationCount;
    var workerCount = _activeTokens.length;
    // No point running more workers than requested images.
    if (generationCount != 0) {
      workerCount = min(workerCount, generationCount);
    }
    for (var index = 1; index < workerCount; index++) {
      _extraWorkers[index] = _WorkerState();
      _nextCommandForExtraWorker(index);
    }
  }

  void _clearExtraWorkers() {
    for (final state in _extraWorkers.values) {
      state.intervalTimer?.cancel();
    }
    _extraWorkers.clear();
  }

  void _cancelWorkerIntervals() {
    for (final state in _extraWorkers.values) {
      state.intervalTimer?.cancel();
      state.intervalTimer = null;
    }
  }

  void startGeneration() {
    final paramConfig = payloadConfig.paramConfig;
    if (!paramConfig.randomSeed && paramConfig.seed == null) {
      paramConfig.seed = 0;
      notifyListeners();
    }
    _generationIntervalTimer?.cancel();
    commandStatus.isWaitingForNextGeneration.value = false;
    _primaryConsecutiveFailures = 0;
    _primaryWorkerPaused = false;
    if (!payloadConfig.settings.rememberSequentialProgress) {
      payloadConfig.resetSequentialState();
      _cachedPayloadResult = null;
      _cachedI2iBatch = null;
      _cachedRetryFingerprint = null;
      _cachedDiagnosticContext = null;
    }
    _clearExtraWorkers();
    if (lockToAllCombinations) {
      payloadConfig.settings.generationCount = totalCombinations;
    }
    final tokens = payloadConfig.settings.effectiveApiTokens;
    final generationCount = payloadConfig.settings.generationCount;
    var workerCount = tokens.length;
    if (generationCount != 0) workerCount = min(workerCount, generationCount);
    final activeEntries = tokens.take(workerCount).toList(growable: false);
    _activeTokens =
        activeEntries.map((entry) => entry.token).toList(growable: false);
    _activeTokenLabels =
        activeEntries.map((entry) => entry.label).toList(growable: false);
    if (_activeTokens.isEmpty) return;
    _logicalTasks.clear();
    _scheduler = GenerationScheduler(
      taskCount: generationCount,
      workerIds: List.generate(workerCount, (index) => index.toString()),
    );
    final batch = _BatchAccounting(
      List<String>.of(_activeTokens),
      reconcileBalances: !payloadConfig.settings.debugApiEnabled,
    );
    for (final token in _activeTokens) {
      final knownBalance = _lastAnlasBalances[token];
      if (knownBalance != null) batch.startingBalances[token] = knownBalance;
    }
    _activeBatch = batch;
    if (batch.reconcileBalances) {
      for (final token in _activeTokens) {
        batch.baselineFutures[token] =
            _captureBatchStartingBalance(batch, token);
      }
    }
    commandStatus.currentGenerationCount = 0;
    commandStatus.isStopping.value = false;
    commandStatus.isGenerationActive.value = true;
    commandStatus.generationTimestamp = DateTime.now();
    nextCommand();
    _startExtraWorkers();
  }

  void _finishScheduledBatchIfNeeded() {
    if (_scheduler?.status.finished == true) {
      stopGeneration();
    }
  }

  void stopGeneration() {
    final scheduler = _scheduler;
    if (!commandStatus.isStopping.value) {
      commandStatus.isStopping.value = true;
      scheduler?.requestStop();
      _generationIntervalTimer?.cancel();
      _generationIntervalTimer = null;
      _cancelWorkerIntervals();
      commandStatus.isWaitingForNextGeneration.value = false;
    }
    if (scheduler != null && !scheduler.status.finished) {
      return;
    }
    _completeGenerationStop();
  }

  void _completeGenerationStop() {
    _clearExtraWorkers();
    commandStatus.isGenerationActive.value = false;
    commandStatus.isStopping.value = false;
    final batch = _activeBatch;
    _activeBatch = null;
    if (batch != null) {
      batch.stopped = true;
      if (batch.reconcileBalances) _tryFinalizeBatch(batch);
    }
    _scheduler = null;
    _primaryLease = null;
  }

  void scheduleNextGeneration({Duration minimumDelay = Duration.zero}) {
    if (!commandStatus.isGenerationActive.value) return;

    _generationIntervalTimer?.cancel();
    final configuredDelay = Duration(
      seconds: payloadConfig.settings.generationIntervalSec,
    );
    final delay = configuredDelay.compareTo(minimumDelay) >= 0
        ? configuredDelay
        : minimumDelay;
    if (delay == Duration.zero) {
      nextCommand();
      return;
    }

    commandStatus.isWaitingForNextGeneration.value = true;
    _generationIntervalTimer = Timer(delay, () {
      _generationIntervalTimer = null;
      commandStatus.isWaitingForNextGeneration.value = false;
      nextCommand();
    });
  }

  @visibleForTesting
  void continueAfterGenerationAttempt() {
    if (!commandStatus.isGenerationActive.value) return;

    final schedulerStatus = _scheduler?.status;
    if (schedulerStatus?.stopRequested == true) {
      if (schedulerStatus!.finished) stopGeneration();
      return;
    }

    final generationCount = payloadConfig.settings.generationCount;
    if (generationCount != 0 &&
        commandStatus.currentGenerationCount >= generationCount) {
      stopGeneration();
      return;
    }
    if (_primaryConsecutiveFailures >= 5) {
      _primaryWorkerPaused = true;
      if (_allWorkersPaused) stopGeneration();
      return;
    }
    scheduleNextGeneration(
      minimumDelay: _failureBackoff(_primaryConsecutiveFailures),
    );
  }

  void toggleGeneration() {
    if (commandStatus.isStopping.value) return;
    if (commandStatus.isGenerationActive.value) {
      stopGeneration();
    } else {
      startGeneration();
    }
  }

  @override
  void dispose() {
    _generationIntervalTimer?.cancel();
    _clearExtraWorkers();
    nextCostEstimate.dispose();
    super.dispose();
  }

  /// Make PayloadResult into readable Map<String, dynamic> for better visualization
  Map<String, dynamic> digestPayloadResult(
    PayloadGenerationResult payloadResult,
  ) {
    // 明确将 payload 转换为可空动态类型
    final additionalInfo = Map<String, dynamic>.from(payloadResult.payload);

    // 使用 Map.from 确保 parameters 的类型为 Map<String, dynamic>
    final additionalInfoParam = Map<String, dynamic>.from(
      additionalInfo['parameters']! as Map,
    );

    // 移除不需要的键
    for (final key in [
      'reference_image_multiple',
      'reference_information_extracted_multiple',
      'reference_strength_multiple',
      'director_reference_images',
      'director_reference_descriptions',
      'director_reference_information_extracted',
      'director_reference_strength_values',
      'director_reference_secondary_strength_values',
      'image',
      'mask',
    ]) {
      additionalInfoParam.remove(key);
    }

    additionalInfo.remove('parameters');

    // 合并时使用显式类型转换
    additionalInfo.addAll(additionalInfoParam.cast<String, dynamic>());

    return additionalInfo;
  }

  String _getSafeFileName(String fileName) {
    String safeName = fileName.replaceAll(RegExp(r'[<>"/\\|?*{}\[\]]'), '');
    safeName = safeName.replaceAll(RegExp(r'[:]'), '_');
    return safeName.substring(0, min(200, safeName.length));
  }

  void setUC(String value) {
    payloadConfig.setNegativePromptFromString(value);
    notifyListeners();
  }
}
