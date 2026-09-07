import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/opus_usage.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/token_manager_viewmodel.dart';
import 'package:nai_casrand/ui/settings_page/view_models/settings_page_viewmodel.dart';

class _FakeAccountService extends AccountService {
  final List<String> queriedTokens = [];
  final List<bool> forceRefreshValues = [];
  final List<({String? token, String? proxy})> invalidations = [];

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    queriedTokens.add(token);
    forceRefreshValues.add(forceRefresh);
    return SubscriptionInfo(
      anlas: 100,
      tier: 1,
      active: true,
      usage: OpusUsage(
        percent: 73,
        isNegative: false,
        secondsPerPercent: 6048,
        observedAt: DateTime(2026),
      ),
      expiresAt: DateTime(2026, 9, 1),
    );
  }

  @override
  void invalidate({String? token, String? proxy}) {
    invalidations.add((token: token, proxy: proxy));
  }
}

class _QueuedAccountService extends AccountService {
  final List<Completer<SubscriptionInfo?>> pending = [];

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) {
    final completer = Completer<SubscriptionInfo?>();
    pending.add(completer);
    return completer.future;
  }
}

SubscriptionInfo _subscription(int anlas) => SubscriptionInfo(
      anlas: anlas,
      tier: 1,
      active: true,
    );

class _FakeConfigService extends ConfigService {
  int saveCount = 0;

  @override
  Future<void> saveConfig(Map<String, dynamic> jsonData) async {
    saveCount++;
  }
}

PayloadConfig _payloadConfig() {
  return PayloadConfig(
    rootPromptConfig: PromptConfig(strs: [], prompts: []),
    negativePromptConfig: PromptConfig(strs: [], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(),
    settings: Settings.fromJson({'api_key': 'pst-main'}),
    overridePrompt: '',
    useOverridePrompt: false,
    useCharacterPromptWithOverride: false,
  );
}

void main() {
  late _FakeAccountService accountService;
  late _FakeConfigService configService;

  setUp(() async {
    await GetIt.I.reset();
    accountService = _FakeAccountService();
    configService = _FakeConfigService();
    GetIt.I.registerSingleton<PayloadConfig>(_payloadConfig());
    GetIt.I.registerSingleton<ConfigService>(configService);
  });

  tearDown(() => GetIt.I.reset());

  test('additional tokens are trimmed and unique while main token is locked',
      () async {
    final viewmodel = TokenManagerViewmodel(accountService: accountService);

    expect(viewmodel.addToken('  Secondary  ', '  pst-secondary  '), isTrue);
    expect(viewmodel.addToken('Duplicate', 'pst-secondary'), isFalse);
    viewmodel.removeTokenAt(0);
    await Future<void>.delayed(Duration.zero);

    expect(viewmodel.tokens.map((entry) => entry.token), [
      'pst-main',
      'pst-secondary',
    ]);
    expect(viewmodel.tokens[1].label, 'Secondary');
    expect(viewmodel.tokens.first.isPrimary, isTrue);
    expect(accountService.queriedTokens, ['pst-secondary']);
    expect(accountService.forceRefreshValues, [true]);
    expect(viewmodel.subscriptionFor('pst-secondary')?.usage?.percent, 73);
    expect(
      viewmodel.subscriptionFor('pst-secondary')?.expiresAt,
      DateTime(2026, 9, 1),
    );
    expect(configService.saveCount, 1);
  });

  test('at most six accounts can be enabled and a freed slot can be reused',
      () async {
    final viewmodel = TokenManagerViewmodel(accountService: accountService);

    for (var index = 1; index <= 6; index++) {
      expect(viewmodel.addToken('T$index', 'pst-$index'), isTrue);
    }
    await Future<void>.delayed(Duration.zero);

    expect(viewmodel.enabledTokenCount, 6);
    expect(viewmodel.tokens.last.enabled, isFalse);
    viewmodel.setTokenEnabled(viewmodel.tokens.length - 1, true);
    expect(viewmodel.tokens.last.enabled, isFalse);

    viewmodel.setTokenEnabled(1, false);
    viewmodel.setTokenEnabled(viewmodel.tokens.length - 1, true);
    expect(viewmodel.enabledTokenCount, 6);
    expect(viewmodel.tokens.last.enabled, isTrue);
  });

  test('refresh all balances bypasses subscription cache for every token',
      () async {
    final viewmodel = TokenManagerViewmodel(accountService: accountService);
    viewmodel.addToken('Secondary', 'pst-secondary');
    await Future<void>.delayed(Duration.zero);
    await viewmodel.refreshAllBalances();

    expect(
        accountService.queriedTokens,
        containsAll(<String>[
          'pst-main',
          'pst-secondary',
        ]));
    expect(accountService.forceRefreshValues, everyElement(isTrue));
    expect(accountService.forceRefreshValues, hasLength(3));
  });

  test(
      'list order is dispatch priority and disabling all accounts turns off parallel mode',
      () async {
    final viewmodel = TokenManagerViewmodel(accountService: accountService);
    viewmodel.addToken('Secondary', 'pst-secondary');
    await Future<void>.delayed(Duration.zero);
    viewmodel.setParallelApiEnabled(true);

    viewmodel.reorderToken(1, 0);
    expect(
      GetIt.I<PayloadConfig>()
          .settings
          .effectiveApiTokens
          .map((entry) => entry.token),
      ['pst-secondary', 'pst-main'],
    );

    viewmodel.reorderToken(0, 1);
    expect(
      GetIt.I<PayloadConfig>()
          .settings
          .effectiveApiTokens
          .map((entry) => entry.token),
      ['pst-main', 'pst-secondary'],
    );

    viewmodel.setTokenEnabled(0, false);
    viewmodel.setTokenEnabled(1, false);
    expect(viewmodel.parallelApiEnabled, isFalse);
    expect(
      GetIt.I<PayloadConfig>().settings.effectiveApiTokens.single.token,
      'pst-main',
    );
  });

  test('removing a token invalidates its account cache and HTTP route',
      () async {
    final viewmodel = TokenManagerViewmodel(accountService: accountService);
    viewmodel.addToken('Secondary', 'pst-secondary');
    await Future<void>.delayed(Duration.zero);

    viewmodel.removeTokenAt(1);

    expect(
      accountService.invalidations,
      contains((token: 'pst-secondary', proxy: null)),
    );
  });

  test('a stale balance response cannot replace a newer refresh', () async {
    final queued = _QueuedAccountService();
    final viewmodel = TokenManagerViewmodel(accountService: queued);

    final older = viewmodel.refreshBalance('pst-main');
    final newer = viewmodel.refreshBalance('pst-main');
    expect(queued.pending, hasLength(2));

    queued.pending[1].complete(_subscription(200));
    await newer;
    queued.pending[0].complete(_subscription(100));
    await older;

    expect(viewmodel.balances['pst-main'], 200);
    expect(viewmodel.isBalanceLoading('pst-main'), isFalse);
  });

  test('finishing a balance request after dispose is ignored', () async {
    final queued = _QueuedAccountService();
    final viewmodel = TokenManagerViewmodel(accountService: queued);
    final pending = viewmodel.refreshBalance('pst-main');
    viewmodel.dispose();

    queued.pending.single.complete(_subscription(100));

    await expectLater(pending, completes);
  });

  test('replacing credentials and proxy invalidates their old routes', () {
    final viewmodel = SettingsPageViewmodel(accountService: accountService);

    viewmodel.setApiKey('pst-replacement');
    viewmodel.setProxy('proxy.example:8080');

    expect(accountService.invalidations, [
      (token: 'pst-main', proxy: null),
      (token: null, proxy: ''),
    ]);
  });
}
