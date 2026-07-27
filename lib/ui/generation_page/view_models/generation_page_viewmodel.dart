import 'dart:async';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/director_tool_config.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:lorem_ipsum/lorem_ipsum.dart';
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/data/use_cases/anlas_cost.dart';
import 'package:nai_casrand/data/use_cases/generate_payload_use_case.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';

const infoCardContentListLength = 200;

/// Per-worker generation state. Worker 0 is the legacy single-token path;
/// additional workers exist only while multiple API tokens are enabled.
class _WorkerState {
  PayloadGenerationResult? cachedPayloadResult;
  I2iRequestBatch? cachedI2iBatch;
  int cacheRetriesCount = 0;
  Timer? intervalTimer;
  Command<void, InfoCardContent>? command;
}

class GenerationPageViewmodel extends ChangeNotifier {
  PayloadConfig get payloadConfig => GetIt.I<PayloadConfig>();
  CommandStatus get commandStatus => GetIt.I<CommandStatus>();
  List<Command<void, InfoCardContent>> get commandList =>
      commandStatus.commandList;
  int get colNum => payloadConfig.settings.generationPageColumnCount;

  Command<void, InfoCardContent>? currentCommand;
  Command<void, InfoCardContent>? lastEnhanceCommand;
  Command<void, InfoCardContent>? lastDirectorCommand;

  PayloadGenerationResult? _cachedPayloadResult;
  I2iRequestBatch? _cachedI2iBatch;
  int _cacheRetriesCount = 0;
  Timer? _generationIntervalTimer;

  /// Tokens captured at generation start; index-aligned with workers.
  List<String> _activeTokens = [];
  List<String> _activeTokenLabels = [];
  final Map<int, _WorkerState> _extraWorkers = {};

  /// Last known Anlas balance per token (updated after each generation).
  final Map<String, int> _lastAnlasBalances = {};
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
      !payloadConfig.i2iConfig.hasImage;

  /// Whether SMEA multipliers apply to the current model (V4 models drop the
  /// sm flags from the payload entirely).
  bool get _smActive =>
      !payloadConfig.paramConfig.model.contains('diffusion-4');

  /// Recomputes [nextCostEstimate] when any relevant input changed. Cheap to
  /// call from build methods: a fingerprint short-circuits repeats, and the
  /// img2img planning that needs image decoding runs asynchronously.
  void refreshCostEstimate() {
    refreshSubscriptionSnapshot();
    final paramConfig = payloadConfig.paramConfig;
    final i2i = payloadConfig.i2iConfig;
    final sizes = i2i.hasImage ? [i2i.requestSize] : paramConfig.sizes;
    if (sizes.isEmpty) return;
    if (!payloadConfig.settings.subscriptionStatusKnown) {
      nextCostEstimate.value = null;
      return;
    }
    final sm = _smActive && paramConfig.sm;
    final smDyn = _smActive && paramConfig.smDyn;
    final key = [
      i2i.hasImage,
      i2i.revision,
      sizes.map((size) => '${size.width}x${size.height}').join(','),
      paramConfig.steps,
      sm,
      smDyn,
      payloadConfig.settings.subscriptionTier,
      payloadConfig.settings.subscriptionActive,
      payloadConfig.preciseReferenceConfigList
          .where((reference) => reference.enabled)
          .length,
      payloadConfig.vibeConfigListV4.length,
      paramConfig.nSamples,
    ].join('|');
    if (key == _costEstimateKey) return;
    _costEstimateKey = key;
    final epoch = ++_costEstimateEpoch;
    _computeCostEstimate(epoch);
  }

  Future<void> _computeCostEstimate(int epoch) async {
    final paramConfig = payloadConfig.paramConfig;
    final i2i = payloadConfig.i2iConfig;
    final tier = payloadConfig.settings.subscriptionTier;
    final subscriptionActive = payloadConfig.settings.subscriptionActive;
    final sm = _smActive && paramConfig.sm;
    final smDyn = _smActive && paramConfig.smDyn;
    final preciseCount = payloadConfig.preciseReferenceConfigList
        .where((reference) => reference.enabled)
        .length;
    final vibeCount = payloadConfig.vibeConfigListV4.length;
    // With several sizes one is picked at random per request; estimate the
    // most expensive so the display is an honest upper bound.
    final sizes = i2i.hasImage ? [i2i.requestSize] : paramConfig.sizes;
    var largest = sizes.first;
    for (final size in sizes) {
      if (size.width * size.height > largest.width * largest.height) {
        largest = size;
      }
    }

    AnlasCost? estimate;
    try {
      if (!i2i.hasImage) {
        estimate = estimateAnlasCost(
          width: largest.width,
          height: largest.height,
          steps: paramConfig.steps,
          sm: sm,
          smDyn: smDyn,
          tier: tier,
          subscriptionActive: subscriptionActive,
          nSamples: paramConfig.nSamples,
          preciseReferenceCount: preciseCount,
          vibeCount: vibeCount,
        );
      } else {
        final batch = await PrepareI2iRequestUseCase(
          config: i2i,
        ).planBatch(targetWidth: largest.width, targetHeight: largest.height);
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
    if (epoch != _costEstimateEpoch) return;
    nextCostEstimate.value = estimate;
  }

  /// Refreshes the active account used for the pre-generation price display.
  /// Calls within one minute are coalesced; the actual generation path still
  /// refreshes again immediately before sending.
  Future<void> refreshSubscriptionSnapshot() async {
    if (_subscriptionRefreshInFlight) return;
    final settings = payloadConfig.settings;
    if (settings.debugApiEnabled) {
      settings.subscriptionTier = 0;
      settings.subscriptionActive = false;
      settings.subscriptionStatusKnown = true;
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
      return;
    }
    _subscriptionRefreshInFlight = true;
    _lastSubscriptionRefreshAttempt = now;
    final info = await AccountService().fetchSubscription(
      token: tokens.first.token,
      proxy: settings.proxy,
    );
    _subscriptionRefreshInFlight = false;
    if (info == null) {
      settings.subscriptionStatusKnown = false;
    } else {
      settings.subscriptionTier = info.tier;
      settings.subscriptionActive = info.active;
      settings.subscriptionStatusKnown = true;
      if (info.anlas != null) {
        _lastAnlasBalances[tokens.first.token] = info.anlas!;
      }
    }
    _costEstimateKey = null;
    notifyListeners();
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

  void setGenerationCount(String value) {
    final parseResult = int.tryParse(value);
    if (parseResult == null || parseResult < 0) return;
    payloadConfig.settings.generationCount = parseResult;
    notifyListeners();
  }

  void addAndRunCommand(Command<void, InfoCardContent> command) {
    // Make sure list is not longer than expected
    while (commandList.length >= infoCardContentListLength) {
      commandList.removeAt(0);
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

  void addTestPromptInfoCardContent() {
    // Sync command but wrapped as async
    commandFunc() async {
      final payloadResult = GeneratePayloadUseCase(
        payloadConfig: payloadConfig,
      )();
      final additionalInfo = digestPayloadResult(payloadResult);
      return InfoCardContent(
        title: tr('test_prompt'),
        info: payloadResult.comment,
        additionalInfo: additionalInfo,
      );
    }

    // Skip the check of active command (because command is sync)
    final command = Command.createAsyncNoParam(
      commandFunc,
      initialValue: InfoCardContent.fromEmpty(),
    );
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
    final canvas = useCase.newCompositeCanvas();
    Uint8List? lastResponse;

    Map<String, dynamic> payloadFor(I2iRequestPlan plan) {
      return GeneratePayloadUseCase(
        payloadConfig: payloadConfig,
        i2iPlan: plan,
      )()
          .payload;
    }

    if (batch.serial) {
      for (final plan in batch.plans) {
        // Re-plan against the canvas as it stands so later tiles build on the
        // already-repainted pixels.
        final response = await sendPlan(payloadFor(plan));
        useCase.pasteTileInto(
          canvas: canvas,
          responseBytes: response,
          composite: plan.composite!,
        );
        lastResponse = response;
      }
    } else {
      for (var start = 0;
          start < batch.plans.length;
          start += maxTileConcurrency) {
        final slice = batch.plans.skip(start).take(maxTileConcurrency).toList();
        final responses = await Future.wait(
          slice.map((plan) => sendPlan(payloadFor(plan))),
        );
        for (final (index, response) in responses.indexed) {
          useCase.pasteTileInto(
            canvas: canvas,
            responseBytes: response,
            composite: slice[index].composite!,
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
  }) {
    commandFunc() async {
      final settings = payloadConfig.settings;
      final endpoint = settings.debugApiEnabled
          ? settings.debugApiPath
          : 'https://image.novelai.net/ai/generate-image';
      final token = _tokenForWorker(workerIndex);

      PayloadGenerationResult? payloadResult;
      try {
        // Check whether cached payload exists, use cache if exists
        I2iRequestBatch? i2iBatch;
        if (presetBatch != null) {
          i2iBatch = presetBatch;
          payloadResult = GeneratePayloadUseCase(
            payloadConfig: payloadConfig,
            i2iPlan: i2iBatch.plans.first,
          )();
        } else if (_getCachedPayload(workerIndex) != null &&
            _getCacheRetries(workerIndex) < 3) {
          payloadResult = _getCachedPayload(workerIndex)!;
          i2iBatch = _getCachedBatch(workerIndex);
          _setCacheRetries(workerIndex, _getCacheRetries(workerIndex) + 1);
        } else {
          final i2iConfig = payloadConfig.i2iConfig;
          if (i2iConfig.hasImage) {
            final target = i2iConfig.requestSize;
            i2iBatch = await PrepareI2iRequestUseCase(
              config: i2iConfig,
            ).planBatch(targetWidth: target.width, targetHeight: target.height);
          }
          payloadResult = GeneratePayloadUseCase(
            payloadConfig: payloadConfig,
            i2iPlan: i2iBatch?.plans.first,
          )();
          _setCachedPayload(workerIndex, payloadResult, i2iBatch);
          _setCacheRetries(workerIndex, 0);
        }

        // Fetch the starting balance once per token so cost can be derived,
        // and record the tier so cost estimates know about Opus.
        if (!settings.debugApiEnabled) {
          final info = await AccountService().fetchSubscription(
            token: token,
            proxy: settings.proxy,
          );
          if (info == null) {
            settings.subscriptionStatusKnown = false;
          } else {
            if (info.anlas != null) _lastAnlasBalances[token] = info.anlas!;
            settings.subscriptionTier = info.tier;
            settings.subscriptionActive = info.active;
            settings.subscriptionStatusKnown = true;
          }
        }

        final headers = payloadConfig.getHeadersForToken(token);
        Future<Uint8List> sendPlan(Map<String, dynamic> payload) async {
          final response = await ApiService().fetchData(
            ApiRequest(
              endpoint: endpoint,
              proxy: settings.proxy,
              headers: headers,
              payload: payload,
            ),
          );
          // Even if response status is not 2xx, postprocess could throw
          // the correct exception.
          return ImageService().processResponse(response.data);
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
          // Paste the focus frame back into the original image.
          final composite = i2iBatch?.plans.first.composite;
          if (composite != null) {
            imageBytes = await PrepareI2iRequestUseCase(
              config: payloadConfig.i2iConfig,
            ).compositeResponse(
              responseBytes: imageBytes,
              composite: composite,
            );
          }
        }
        // Add custom metadata
        if (settings.metadataEraseEnabled) {
          final metadataString = settings.customMetadataEnabled
              ? settings.customMetadataContent
              : '';
          imageBytes = await ImageService().embedMetadata(
            imageBytes,
            metadataString,
          );
        }
        // Save image
        final filePrefix = payloadResult.suggestedFileName.isNotEmpty
            ? _getSafeFileName(payloadResult.suggestedFileName)
            : '';
        final fileName = [
          FileService().generateTimestampString(
            commandStatus.generationTimestamp,
          ),
          commandStatus.currentGenerationCount.toString().padLeft(6, '0'),
          filePrefix,
          '${FileService().generateRandomString()}.png',
        ].join('-');
        final imageFilePath = await FileService().savePictureToFile(
          imageBytes,
          fileName,
          settings.outputFolderPath,
        );
        // Anlas cost via balance difference (token-sequential, so exact).
        int? anlasCost;
        int? anlasRemaining;
        if (!settings.debugApiEnabled) {
          final previousBalance = _lastAnlasBalances[token];
          final newBalance = await AccountService().fetchAnlasBalance(
            token: token,
            proxy: settings.proxy,
          );
          if (newBalance != null) {
            anlasRemaining = newBalance;
            if (previousBalance != null && previousBalance >= newBalance) {
              anlasCost = previousBalance - newBalance;
            }
            _lastAnlasBalances[token] = newBalance;
          }
        }
        // Reset cache after successful generation
        _setCachedPayload(workerIndex, null, null);
        // Only increment total count after successful generation
        commandStatus.currentGenerationCount++;
        return InfoCardContent(
          title: fileName,
          info: payloadResult.comment,
          additionalInfo: digestPayloadResult(payloadResult),
          imageBytes: imageBytes,
          imageFilePath: imageFilePath,
          anlasCost: anlasCost,
          anlasRemaining: anlasRemaining,
          tokenLabel: _tokenLabelForWorker(workerIndex),
        );
      } catch (e) {
        return InfoCardContent(
          title: 'Error occurred in generation process.',
          info: e.toString(),
          additionalInfo:
              payloadResult != null ? digestPayloadResult(payloadResult) : {},
          tokenLabel: _tokenLabelForWorker(workerIndex),
        );
      }
    }

    return Command.createAsyncNoParam(
      commandFunc,
      initialValue: InfoCardContent.fromEmpty(),
    );
  }

  PayloadGenerationResult? _getCachedPayload(int workerIndex) {
    if (workerIndex == 0) return _cachedPayloadResult;
    return _extraWorkers[workerIndex]?.cachedPayloadResult;
  }

  I2iRequestBatch? _getCachedBatch(int workerIndex) {
    if (workerIndex == 0) return _cachedI2iBatch;
    return _extraWorkers[workerIndex]?.cachedI2iBatch;
  }

  void _setCachedPayload(
    int workerIndex,
    PayloadGenerationResult? result,
    I2iRequestBatch? batch,
  ) {
    if (workerIndex == 0) {
      _cachedPayloadResult = result;
      _cachedI2iBatch = batch;
      return;
    }
    final state = _extraWorkers[workerIndex];
    if (state == null) return;
    state.cachedPayloadResult = result;
    state.cachedI2iBatch = batch;
  }

  int _getCacheRetries(int workerIndex) {
    if (workerIndex == 0) return _cacheRetriesCount;
    return _extraWorkers[workerIndex]?.cacheRetriesCount ?? 0;
  }

  void _setCacheRetries(int workerIndex, int value) {
    if (workerIndex == 0) {
      _cacheRetriesCount = value;
      return;
    }
    _extraWorkers[workerIndex]?.cacheRetriesCount = value;
  }

  void nextCommand() {
    if (!commandStatus.isGenerationActive.value) return;
    if (commandStatus.isWaitingForNextGeneration.value) return;

    // Skip if active command exists
    if (currentCommand != null && currentCommand!.isExecuting.value) return;

    // Create command and attach post-command operations
    final command = createGenerationCommand(workerIndex: 0);
    command.isExecuting.addListener(() {
      notifyListeners();
      // Only update after execution
      if (command.isExecuting.value) return;

      continueAfterGenerationAttempt();
    });

    // Execute command
    currentCommand = command;
    addAndRunCommand(command);
  }

  /// Runs one Director Tool against its source image. These go to the
  /// augment-image endpoint; they are billed by pixel count, and the Opus
  /// free allowance does not apply.
  void runDirectorTool() {
    if (commandStatus.isGenerationActive.value) return;
    if (currentCommand != null && currentCommand!.isExecuting.value) return;
    final config = payloadConfig.directorToolConfig;
    if (!config.hasImage) return;
    commandStatus.generationTimestamp = DateTime.now();

    commandFunc() async {
      final settings = payloadConfig.settings;
      final payload = config.getPayload();
      final toolName = config.displayName;
      try {
        final response = await ApiService().fetchData(
          ApiRequest(
            endpoint: augmentImageEndpoint,
            proxy: settings.proxy,
            headers: payloadConfig.getHeadersForToken(settings.apiKey),
            payload: payload,
          ),
        );
        var imageBytes = ImageService().processResponse(response.data);
        if (settings.metadataEraseEnabled) {
          final metadataString = settings.customMetadataEnabled
              ? settings.customMetadataContent
              : '';
          imageBytes = await ImageService().embedMetadata(
            imageBytes,
            metadataString,
          );
        }
        final fileName = [
          FileService().generateTimestampString(
            commandStatus.generationTimestamp,
          ),
          commandStatus.currentGenerationCount.toString().padLeft(6, '0'),
          config.type,
          '${FileService().generateRandomString()}.png',
        ].join('-');
        final imageFilePath = await FileService().savePictureToFile(
          imageBytes,
          fileName,
          settings.outputFolderPath,
        );
        commandStatus.currentGenerationCount++;
        // The request carries the source image inline; keep it out of the card.
        final info = Map<String, dynamic>.from(payload)..remove('image');
        return InfoCardContent(
          title: fileName,
          info:
              '$toolName\n${info.entries.map((e) => '${e.key}: ${e.value}').join('\n')}',
          additionalInfo: info,
          imageBytes: imageBytes,
          imageFilePath: imageFilePath,
        );
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
    command.isExecuting.addListener(notifyListeners);
    lastDirectorCommand = command;
    currentCommand = command;
    addAndRunCommand(command);
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
    if (commandStatus.isGenerationActive.value) return false;
    if (currentCommand != null && currentCommand!.isExecuting.value) {
      return false;
    }
    final enhance = payloadConfig.enhanceConfig;
    final bytes = enhance.imageBytes;
    if (bytes == null) return false;
    final target = enhance.targetSize;
    final paramConfig = payloadConfig.paramConfig;
    if (!paramConfig.randomSeed && paramConfig.seed == null) {
      paramConfig.seed = 0;
    }

    // A throwaway I2IConfig reuses the img2img plan builder (cover-fit resize
    // and PNG encoding) without touching the real Img2Img base image.
    final requestConfig = I2IConfig(
      strength: enhance.strength,
      noise: enhance.noise,
    );
    requestConfig.setImage(bytes);
    final plan = await PrepareI2iRequestUseCase(
      config: requestConfig,
    ).call(targetWidth: target.width, targetHeight: target.height);
    if (plan == null) return false;

    commandStatus.generationTimestamp = DateTime.now();
    final command = createGenerationCommand(
      workerIndex: 0,
      presetBatch: I2iRequestBatch(
        plans: [plan],
        serial: true,
        summary: plan.summary,
      ),
    );
    command.isExecuting.addListener(notifyListeners);
    lastEnhanceCommand = command;
    currentCommand = command;
    addAndRunCommand(command);
    return true;
  }

  void clearEnhanceResult() {
    lastEnhanceCommand = null;
    notifyListeners();
  }

  void _nextCommandForExtraWorker(int workerIndex) {
    if (!commandStatus.isGenerationActive.value) return;
    final state = _extraWorkers[workerIndex];
    if (state == null) return;
    if (state.command != null && state.command!.isExecuting.value) return;

    final command = createGenerationCommand(workerIndex: workerIndex);
    command.isExecuting.addListener(() {
      notifyListeners();
      if (command.isExecuting.value) return;
      _continueExtraWorkerAfterAttempt(workerIndex);
    });
    state.command = command;
    addAndRunCommand(command);
  }

  void _continueExtraWorkerAfterAttempt(int workerIndex) {
    if (!commandStatus.isGenerationActive.value) return;

    final generationCount = payloadConfig.settings.generationCount;
    if (generationCount != 0 &&
        commandStatus.currentGenerationCount >= generationCount) {
      stopGeneration();
      return;
    }

    final state = _extraWorkers[workerIndex];
    if (state == null) return;
    state.intervalTimer?.cancel();
    final interval = payloadConfig.settings.generationIntervalSec;
    if (interval == 0) {
      _nextCommandForExtraWorker(workerIndex);
      return;
    }
    state.intervalTimer = Timer(Duration(seconds: interval), () {
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

  void startGeneration() {
    final paramConfig = payloadConfig.paramConfig;
    if (!paramConfig.randomSeed && paramConfig.seed == null) {
      paramConfig.seed = 0;
      notifyListeners();
    }
    _generationIntervalTimer?.cancel();
    commandStatus.isWaitingForNextGeneration.value = false;
    if (!payloadConfig.settings.rememberSequentialProgress) {
      payloadConfig.resetSequentialState();
      _cachedPayloadResult = null;
      _cachedI2iBatch = null;
      _cacheRetriesCount = 0;
    }
    _clearExtraWorkers();
    final tokens = payloadConfig.settings.effectiveApiTokens;
    _activeTokens = tokens.map((entry) => entry.token).toList(growable: false);
    _activeTokenLabels =
        tokens.map((entry) => entry.label).toList(growable: false);
    commandStatus.currentGenerationCount = 0;
    commandStatus.isGenerationActive.value = true;
    commandStatus.generationTimestamp = DateTime.now();
    nextCommand();
    _startExtraWorkers();
  }

  void stopGeneration() {
    _generationIntervalTimer?.cancel();
    _generationIntervalTimer = null;
    _clearExtraWorkers();
    commandStatus.isWaitingForNextGeneration.value = false;
    commandStatus.isGenerationActive.value = false;
  }

  void scheduleNextGeneration() {
    if (!commandStatus.isGenerationActive.value) return;

    _generationIntervalTimer?.cancel();
    final interval = payloadConfig.settings.generationIntervalSec;
    if (interval == 0) {
      nextCommand();
      return;
    }

    commandStatus.isWaitingForNextGeneration.value = true;
    _generationIntervalTimer = Timer(Duration(seconds: interval), () {
      _generationIntervalTimer = null;
      commandStatus.isWaitingForNextGeneration.value = false;
      nextCommand();
    });
  }

  @visibleForTesting
  void continueAfterGenerationAttempt() {
    if (!commandStatus.isGenerationActive.value) return;

    final generationCount = payloadConfig.settings.generationCount;
    if (generationCount != 0 &&
        commandStatus.currentGenerationCount >= generationCount) {
      stopGeneration();
      return;
    }
    scheduleNextGeneration();
  }

  void toggleGeneration() {
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
