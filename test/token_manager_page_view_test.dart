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
            'allow_points': false,
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
    expect(
      find.byKey(
        const ValueKey('token-concurrency-pst-primary-account-token'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('token-concurrency-pst-secondary-account-token'),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.account_balance_wallet_outlined), findsOneWidget);
    expect(find.byIcon(Icons.card_giftcard_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.block_outlined), findsOneWidget);
    viewmodel.dispose();
  });

  testWidgets('account concurrency can be changed from the card',
      (tester) async {
    final viewmodel = TokenManagerViewmodel(
      accountService: _NoopAccountService(),
    );

    await tester.pumpWidget(
      MaterialApp(home: TokenManagerPageView(viewmodel: viewmodel)),
    );
    await tester.pumpAndSettle();

    final selector = find.byKey(
      const ValueKey('token-concurrency-pst-primary-account-token'),
    );
    expect(selector, findsOneWidget);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('4').last);
    await tester.pumpAndSettle();

    expect(viewmodel.tokens.first.concurrency, 4);
    viewmodel.dispose();
  });

  testWidgets('account API provider uses the shared selector frame',
      (tester) async {
    final viewmodel = TokenManagerViewmodel(
      accountService: _NoopAccountService(),
    );

    await tester.pumpWidget(
      MaterialApp(home: TokenManagerPageView(viewmodel: viewmodel)),
    );
    await tester.pumpAndSettle();

    final selector = find.byKey(
      const ValueKey('token-api-pst-primary-account-token'),
    );
    expect(selector, findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsNWidgets(2));
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('api_provider_takoma').last);
    await tester.pumpAndSettle();

    expect(viewmodel.tokens.first.apiBaseUrl, 'https://api.takoma.app');
    expect(viewmodel.tokens.first.concurrency, 4);

    // The shared frame hugs its content instead of stretching across the card.
    final concurrencyFrame = find
        .ancestor(
          of: find.byKey(
            const ValueKey('token-concurrency-pst-primary-account-token'),
          ),
          matching: find.byType(IntrinsicWidth),
        )
        .first;
    expect(tester.getSize(concurrencyFrame).width, lessThan(220));
    viewmodel.dispose();
  });
}
