import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/account_service.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/settings_page_viewmodel.dart';
import 'package:nai_casrand/ui/settings_page/view_models/token_manager_viewmodel.dart';
import 'package:nai_casrand/ui/settings_page/widgets/token_manager_page_view.dart';
import 'package:nai_casrand/ui/settings_page/widgets/settings_page_view.dart';
import 'package:nai_casrand/ui/settings_page/widgets/config_selection_page_view.dart';

class Loader extends AssetLoader {
  final Map<String, dynamic> data;
  const Loader(this.data);
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => data;
}

class NetworkForbidden extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('External networking forbidden in audit');
}

class SaveFake extends ConfigService {
  final saves = <Map<String, dynamic>>[];
  @override
  Future<void> saveConfig(Map<String, dynamic> data) async {
    saves.add(data);
  }
}

class AccountFake extends AccountService {
  final pending = <Completer<SubscriptionInfo?>>[];
  @override
  Future<SubscriptionInfo?> fetchSubscription(
      {required String token,
      required String proxy,
      bool forceRefresh = false}) {
    final c = Completer<SubscriptionInfo?>();
    pending.add(c);
    return c.future;
  }

  void finish() {
    for (final c in pending) {
      if (!c.isCompleted) {
        c.complete(const SubscriptionInfo(anlas: 100, tier: 1, active: true));
      }
    }
  }
}

PayloadConfig config() => PayloadConfig(
    rootPromptConfig: PromptConfig(strs: [], prompts: []),
    negativePromptConfig: PromptConfig(strs: [], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(),
    settings: Settings.fromJson({'api_key': 'TOKEN_MAIN_FIXTURE'}),
    overridePrompt: '',
    useOverridePrompt: false,
    useCharacterPromptWithOverride: false);
void main() {
  late Map<String, dynamic> en, zh;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/shared_preferences'),
            (call) async =>
                call.method == 'getAll' ? <String, Object>{} : true);
    await EasyLocalization.ensureInitialized();
    en = jsonDecode(await rootBundle.loadString('assets/l10n/en.json'));
    zh = jsonDecode(await rootBundle.loadString('assets/l10n/zh-CN.json'));
  });
  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton<PayloadConfig>(config());
    GetIt.I.registerSingleton<ConfigService>(SaveFake());
    GetIt.I.registerSingleton<NavigationRequest>(NavigationRequest());
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await GetIt.I.reset();
  });
  Widget wrap(Widget home, {bool chinese = false, double textScale = 1}) =>
      EasyLocalization(
          key: UniqueKey(),
          supportedLocales: [
            chinese ? const Locale('zh', 'CN') : const Locale('en')
          ],
          path: 'test',
          assetLoader: Loader(chinese ? zh : en),
          saveLocale: false,
          child: Builder(
              builder: (context) => AdaptiveTheme(
                  light: ThemeData.light(),
                  dark: ThemeData.dark(),
                  initial: AdaptiveThemeMode.light,
                  builder: (theme, darkTheme) => MaterialApp(
                      theme: theme,
                      darkTheme: darkTheme,
                      localizationsDelegates: context.localizationDelegates,
                      supportedLocales: context.supportedLocales,
                      locale: context.locale,
                      builder: (context, child) => MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                              textScaler: TextScaler.linear(textScale)),
                          child: child!),
                      home: home))));
  testWidgets('UI01 global account refresh reenables after initial completion',
      (tester) async {
    final account = AccountFake();
    final vm = TokenManagerViewmodel(accountService: account);
    await tester.pumpWidget(wrap(TokenManagerPageView(viewmodel: vm)));
    await tester.pumpAndSettle();
    final top = find
        .descendant(of: find.byType(AppBar), matching: find.byType(IconButton))
        .first;
    expect(tester.widget<IconButton>(top).onPressed, isNull);
    expect(vm.isRefreshing, isTrue);
    account.finish();
    await tester.pumpAndSettle();
    expect(vm.isRefreshing, isFalse);
    expect(tester.widget<IconButton>(top).onPressed, isNotNull);
    vm.dispose();
  });
  testWidgets('UI02 duplicate account input stays open with correctable draft',
      (tester) async {
    final account = AccountFake();
    final vm = TokenManagerViewmodel(accountService: account);
    await tester.pumpWidget(wrap(TokenManagerPageView(viewmodel: vm)));
    await tester.pumpAndSettle();
    account.finish();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('token-manager-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('token-manager-add-label')), 'DUPLICATE_FIXTURE');
    await tester.enterText(
        find.byKey(const Key('token-manager-add-token')), 'TOKEN_MAIN_FIXTURE');
    await tester.tap(find.byKey(const Key('token-manager-add-confirm')));
    await tester.pumpAndSettle();
    expect(vm.tokens.length, 1);
    expect(find.byKey(const Key('token-manager-add-token')), findsOneWidget);
    vm.dispose();
  });
  testWidgets(
      'UI03 saved config controls fit phone width with real translations',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = GetIt.I<ConfigService>();
    service.currentUuid = 'A';
    service.configIndex = {
      'A': SavedConfigInfo(
          title: 'Current config', lastModified: DateTime(2026)),
      'B': SavedConfigInfo(
          title: 'Saved config second', lastModified: DateTime(2026))
    };
    await tester
        .pumpWidget(wrap(ConfigSelectionPageView(notificationCallback: () {})));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('UI04 Chinese theme chooser displays translated choices',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.binding.setSurfaceSize(const Size(1200, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrap(SettingsPageView(), chinese: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text(zh['theme_mode']));
    await tester.pumpAndSettle();
    final rawChoice = find
        .descendant(of: find.byType(SimpleDialog), matching: find.text('light'))
        .evaluate()
        .length;
    debugDefaultTargetPlatformOverride = null;
    expect(rawChoice, 0);
  });
  testWidgets('UI05 settings remains operable at phone width and large text',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrap(SettingsPageView(), textScale: 2));
    await tester.pumpAndSettle();
    final error = tester.takeException();
    debugDefaultTargetPlatformOverride = null;
    expect(error, isNull);
  });

  testWidgets(
      'UI06 cancel API dialog restores edits even after visiting account manager',
      (tester) async {
    await HttpOverrides.runZoned(() async {
      final account = AccountFake();
      await tester.pumpWidget(wrap(SettingsPageView(
          viewmodel: SettingsPageViewmodel(accountService: account))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('api-proxy-settings-tile')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('api-token-input')), 'TOKEN_CHANGED_FIXTURE');
      await tester.tap(find.byKey(const Key('api-tokens-optional-tile')));
      await tester.pumpAndSettle();
      expect(find.byType(TokenManagerPageView), findsOneWidget);
      await tester.tap(find.byKey(const Key('token-manager-parallel-switch')));
      await tester.pumpAndSettle();
      expect(GetIt.I<PayloadConfig>().settings.parallelApiEnabled, isTrue);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text(en['cancel'])));
      await tester.pumpAndSettle();
      expect(GetIt.I<PayloadConfig>().settings.apiKey, 'TOKEN_MAIN_FIXTURE');
      expect(GetIt.I<PayloadConfig>().settings.parallelApiEnabled, isTrue,
          reason: 'Parent Cancel must not roll back independent child edits');
    },
        createHttpClient: (context) =>
            throw StateError('External networking forbidden in audit'));
  });
  testWidgets('UI07 saved config actionable icons expose accessible labels',
      (tester) async {
    final service = GetIt.I<ConfigService>();
    service.currentUuid = 'A';
    service.configIndex = {
      'A': SavedConfigInfo(
          title: 'Current config', lastModified: DateTime(2026)),
      'B': SavedConfigInfo(
          title: 'Saved config second', lastModified: DateTime(2026))
    };
    final semantics = tester.ensureSemantics();

    await tester
        .pumpWidget(wrap(ConfigSelectionPageView(notificationCallback: () {})));
    await tester.pumpAndSettle();
    try {
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
  });
  testWidgets(
      'settings navigation starts collapsed and expands without changing configuration',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final before = jsonEncode(GetIt.I<PayloadConfig>().settings.toJson());
    await tester.pumpWidget(wrap(SettingsPageView(), chinese: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-directory-list')), findsNothing);
    final expansion = find.byKey(const Key('navigation-settings-expansion'));
    await tester.ensureVisible(expansion);
    await tester.tap(expansion);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-directory-list')), findsOneWidget);
    expect(
        GetIt.I<PayloadConfig>().settings.navigation.orderedDestinations.length,
        7);
    expect(jsonEncode(GetIt.I<PayloadConfig>().settings.toJson()), before);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty account input retains draft and accepts a corrected token',
      (tester) async {
    final account = AccountFake();
    final vm = TokenManagerViewmodel(accountService: account);
    await tester.pumpWidget(wrap(TokenManagerPageView(viewmodel: vm)));
    await tester.pumpAndSettle();
    account.finish();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('token-manager-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('token-manager-add-label')), 'FIXTURE_LABEL');
    await tester.tap(find.byKey(const Key('token-manager-add-confirm')));
    await tester.pumpAndSettle();
    expect(find.text(en['api_token_empty_error']), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byKey(const Key('token-manager-add-token')),
        'TOKEN_CORRECTED_FIXTURE');
    await tester.tap(find.byKey(const Key('token-manager-add-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(vm.tokens.last.label, 'FIXTURE_LABEL');
    expect(vm.tokens.last.token, 'TOKEN_CORRECTED_FIXTURE');
    account.finish();
    await tester.pumpAndSettle();
    vm.dispose();
  });
}
