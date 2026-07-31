import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/token_manager_viewmodel.dart';

class _FakeAccountService extends AccountService {
  final List<String> queriedTokens = [];

  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async {
    queriedTokens.add(token);
    return const SubscriptionInfo(anlas: 100, tier: 1, active: true);
  }
}

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
}
