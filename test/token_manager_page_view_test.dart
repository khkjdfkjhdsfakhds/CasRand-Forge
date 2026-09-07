import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/token_manager_viewmodel.dart';
import 'package:nai_casrand/ui/settings_page/widgets/token_manager_page_view.dart';

class _NoopAccountService extends AccountService {
  @override
  Future<SubscriptionInfo?> fetchSubscription({
    required String token,
    required String proxy,
    bool forceRefresh = false,
  }) async =>
      null;
}

class _NoopConfigService extends ConfigService {
  @override
  Future<void> saveConfig(Map<String, dynamic> jsonData) async {}
}

PayloadConfig _config() => PayloadConfig(
      rootPromptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({
        'api_key': 'pst-primary-account-token',
        'api_tokens': [
          {
            'label': 'Primary account with a long label',
            'token': 'pst-primary-account-token',
            'enabled': true,
            'is_primary': true,
          },
          {
            'label': 'Secondary account with a long label',
            'token': 'pst-secondary-account-token',
            'enabled': true,
            'is_primary': false,
          },
        ],
      }),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

void main() {
  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton<PayloadConfig>(_config());
    GetIt.I.registerSingleton<ConfigService>(_NoopConfigService());
  });

  tearDown(() => GetIt.I.reset());

  testWidgets('all token controls fit at 320 logical pixels', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewmodel = TokenManagerViewmodel(
      accountService: _NoopAccountService(),
    );

    await tester.pumpWidget(
      MaterialApp(home: TokenManagerPageView(viewmodel: viewmodel)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.refresh), findsWidgets);
    expect(find.byType(Switch), findsWidgets);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
    viewmodel.dispose();
  });
}
