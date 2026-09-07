import 'dart:async';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:image/image.dart' as img;

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

class _NoSubscriptionRefreshViewmodel extends GenerationPageViewmodel {
  @override
  Future<void> refreshSubscriptionSnapshot() async {}
}

class _AuditAccountService extends AccountService {
  final List<String> tokens = [];
  @override
  Future<SubscriptionInfo?> fetchSubscription(
      {required String token,
      required String proxy,
      bool forceRefresh = false}) async {
    tokens.add(token);
    return SubscriptionInfo(
        anlas: 1000,
        tier: token == 'TOKEN_A' ? 3 : 1,
        active: true,
        usage: OpusUsage(
            percent: 80,
            isNegative: false,
            secondsPerPercent: 6048,
            observedAt: DateTime.now()));
  }
}

Uint8List directorResponseZip(List<Uint8List> images) {
  final archive = Archive();
  for (final (index, bytes) in images.indexed) {
    archive.addFile(ArchiveFile('image_$index.png', bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

class _PendingAccounts extends AccountService {
  final pending = <String, Completer<SubscriptionInfo?>>{};
  @override
  Future<SubscriptionInfo?> fetchSubscription(
      {required String token,
      required String proxy,
      bool forceRefresh = false}) {
    return (pending[token] = Completer<SubscriptionInfo?>()).future;
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

  testWidgets(
      'GEN-01 single generation after completed batch uses newly selected token',
      (tester) async {
    final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 64, height: 64, numChannels: 3)));
    final response =
        ApiResponse(status: '200', data: directorResponseZip([png]));
    final api = _SequenceApiService([response, response]);
    final files = _RecordingFileService();
    final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: files,
        generatedImageStorage: PngGeneratedImageStorage(fileService: files));
    final config = GetIt.I<PayloadConfig>();
    config.settings
      ..debugApiEnabled = true
      ..generationCount = 1
      ..generationIntervalSec = 0;
    config.settings.updatePrimaryApiKey('TOKEN_A');
    vm.startGeneration();
    for (var i = 0; i < 100 && vm.commandStatus.isGenerationActive.value; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    expect(api.requests, hasLength(1));
    expect(vm.commandStatus.isGenerationActive.value, false);
    expect(api.requests.first.headers['authorization'], 'Bearer TOKEN_A');
    config.settings.updatePrimaryApiKey('TOKEN_B');
    vm.runSingleGeneration();
    for (var i = 0;
        i < 100 &&
            (api.requests.length < 2 ||
                (vm.currentCommand?.isExecuting.value ?? false));
        i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
    vm.dispose();
    await tester.pump();
    expect(api.requests, hasLength(2));
    expect(api.requests.last.headers['authorization'], 'Bearer TOKEN_B');
  });
  test('GEN-02 single generation is blocked while Enhance is preparing',
      () async {
    final gate = Completer<void>();
    final api = _BlockingApiService();
    final files = _RecordingFileService();
    final vm = GenerationPageViewmodel(
        apiService: api,
        fileService: files,
        generatedImageStorage: PngGeneratedImageStorage(fileService: files),
        preparationFeedbackBarrier: () => gate.future);
    final config = GetIt.I<PayloadConfig>();
    config.settings.debugApiEnabled = true;
    final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 64, height: 64, numChannels: 3)));
    config.enhanceConfig.setImage(png);
    final enhancing = vm.runEnhanceGeneration();
    expect(vm.isPreparingEnhance, true);
    vm.runSingleGeneration();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final callsBeforeEnhanceReady = api.calls;
    gate.complete();
    final enhanceAccepted =
        await enhancing.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final totalCalls = api.calls;
    api.response
        .complete(ApiResponse(status: '200', data: directorResponseZip([png])));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    vm.dispose();
    expect(enhanceAccepted, true);
    expect(totalCalls, 1,
        reason: 'Only the originally accepted Enhance action should reach API');
    expect(callsBeforeEnhanceReady, 0,
        reason: 'Preparing another image operation is already busy');
  });
  testWidgets('GEN-03 cost refresh notices additional legacy Vibe images',
      (tester) async {
    final config = GetIt.I<PayloadConfig>();
    config.paramConfig.model = 'nai-diffusion-3';
    config.settings
      ..subscriptionTier = 3
      ..subscriptionActive = true
      ..subscriptionStatusKnown = true;
    final vm = _NoSubscriptionRefreshViewmodel();
    vm.refreshCostEstimate();
    await tester.pump();
    final before = vm.nextCostEstimate.value!.anlas;
    final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 8, height: 8, numChannels: 3)));
    for (var i = 0; i < 5; i++) {
      config.addVibeImage(bytes, 'fixture-$i.png');
    }
    expect(config.activeReferenceUsage.vibeCount, 5);
    vm.refreshCostEstimate();
    await tester.pump();
    final actual = vm.nextCostEstimate.value!.anlas;
    vm.advancedFeaturesChanged();
    vm.refreshCostEstimate();
    await tester.pump();
    final invalidated = vm.nextCostEstimate.value!.anlas;
    vm.dispose();
    expect(invalidated, greaterThan(before));
    expect(actual, invalidated,
        reason:
            'Ordinary refresh after a Vibe edit must not require a separate toggle to invalidate cache');
  });
  testWidgets(
      'GEN-04 switching account refreshes subscription without waiting a minute',
      (tester) async {
    final config = GetIt.I<PayloadConfig>();
    config.settings.updatePrimaryApiKey('TOKEN_A');
    final accounts = _AuditAccountService();
    final vm = GenerationPageViewmodel(accountService: accounts);
    await vm.refreshSubscriptionSnapshot();
    expect(config.settings.subscriptionTier, 3);
    config.settings.updatePrimaryApiKey('TOKEN_B');
    await vm.refreshSubscriptionSnapshot();
    final after = config.settings.subscriptionTier;
    final called = List<String>.of(accounts.tokens);
    vm.dispose();
    expect(called, ['TOKEN_A', 'TOKEN_B']);
    expect(after, 1);
  });

  for (final director in [false, true]) {
    test(
        'Stop during ${director ? 'Director' : 'Enhance'} preparation sends nothing',
        () async {
      final gate = Completer<void>();
      final api = _BlockingApiService();
      final vm = GenerationPageViewmodel(
          apiService: api, preparationFeedbackBarrier: () => gate.future);
      final config = GetIt.I<PayloadConfig>();
      config.settings.debugApiEnabled = true;
      final png = Uint8List.fromList(
          img.encodePng(img.Image(width: 64, height: 64, numChannels: 3)));
      if (director) {
        config.directorToolConfig.setImage(png);
      } else {
        config.enhanceConfig.setImage(png);
      }
      final pending =
          director ? vm.runDirectorTool() : vm.runEnhanceGeneration();
      expect(vm.isBusyPreparingOrSingle, true);
      vm.stopGeneration();
      gate.complete();
      expect(await pending, false);
      expect(api.calls, 0);
      expect(vm.isBusyPreparingOrSingle, false);
      vm.dispose();
    });
  }
  for (final fails in [false, true]) {
    test(
        'GEN-04 late A ${fails ? 'failure' : 'success'} never overwrites selected B',
        () async {
      final settings = GetIt.I<PayloadConfig>().settings;
      settings.updatePrimaryApiKey('TOKEN_A');
      final accounts = _PendingAccounts();
      final vm = GenerationPageViewmodel(accountService: accounts);
      final a = vm.refreshSubscriptionSnapshot();
      settings.updatePrimaryApiKey('TOKEN_B');
      final b = vm.refreshSubscriptionSnapshot();
      accounts.pending['TOKEN_B']!
          .complete(const SubscriptionInfo(tier: 1, active: true, anlas: 100));
      await b;
      if (fails) {
        accounts.pending['TOKEN_A']!.completeError(StateError('fixture'));
      } else {
        accounts.pending['TOKEN_A']!.complete(
            const SubscriptionInfo(tier: 3, active: true, anlas: 900));
      }
      await a;
      expect(settings.subscriptionTier, 1);
      expect(settings.subscriptionStatusKnown, true);
      vm.dispose();
    });
  }
  test('GEN-04 disposed subscription refresh does not write settings',
      () async {
    final settings = GetIt.I<PayloadConfig>().settings;
    settings.updatePrimaryApiKey('TOKEN_A');
    final accounts = _PendingAccounts();
    final vm = GenerationPageViewmodel(accountService: accounts);
    final pending = vm.refreshSubscriptionSnapshot();
    vm.dispose();
    accounts.pending['TOKEN_A']!
        .complete(const SubscriptionInfo(tier: 3, active: true, anlas: 900));
    await pending;
    expect(settings.subscriptionStatusKnown, false);
  });
}
