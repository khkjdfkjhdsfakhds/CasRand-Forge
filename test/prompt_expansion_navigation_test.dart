import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/config_page/widgets/config_page_view.dart';
import 'package:nai_casrand/ui/navigation/widgets/application_navigation_shell.dart';

class _Loader extends AssetLoader {
  final Map<String, dynamic> words;
  _Loader(this.words);
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => words;
}

void main() {
  late Map<String, dynamic> words;
  late PayloadConfig payload;
  late NavigationRequest navigation;
  late NavigationConfiguration configuration;

  PromptConfig leaf(String title) => PromptConfig(
        comment: title,
        strs: ['$title entry'],
        prompts: [],
      );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    words = jsonDecode(await rootBundle.loadString('assets/l10n/en.json'));
  });

  setUp(() async {
    await GetIt.I.reset();
    payload = PayloadConfig(
      rootPromptConfig: PromptConfig(
        comment: 'Base root',
        type: 'config',
        strs: [],
        prompts: [leaf('First group'), leaf('Second group')],
      ),
      negativePromptConfig: PromptConfig(
        comment: 'Negative root',
        type: 'config',
        strs: [],
        prompts: [leaf('Negative group')],
      ),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );
    GetIt.I.registerSingleton<PayloadConfig>(payload);
    navigation = NavigationRequest();
    configuration = NavigationConfiguration.fromJson({});
  });

  tearDown(() async {
    configuration.dispose();
    await GetIt.I.reset();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'fixture',
      assetLoader: _Loader(words),
      startLocale: const Locale('en'),
      saveLocale: false,
      child: Builder(
          builder: (context) => MaterialApp(
                locale: context.locale,
                supportedLocales: context.supportedLocales,
                localizationsDelegates: context.localizationDelegates,
                home: Scaffold(
                    body: ApplicationNavigationShell(
                  configuration: configuration,
                  navigationRequest: navigation,
                  pages: {
                    AppDestination.config:
                        ConfigPageView(viewmodel: ConfigPageViewmodel()),
                    AppDestination.generation:
                        const Text('Generation destination'),
                  },
                )),
              )),
    ));
    await tester.pumpAndSettle();
    navigation.goTo(AppDestination.config);
    await tester.pumpAndSettle();
  }

  Finder tile(String title) => find
      .ancestor(of: find.text(title), matching: find.byType(ExpansionTile))
      .first;

  bool expanded(WidgetTester tester, String title) =>
      ExpansibleController.of(tester.element(find.text(title))).isExpanded;

  Future<void> toggle(WidgetTester tester, String title) async {
    await tester.ensureVisible(tile(title));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<void> leaveAndReturn(WidgetTester tester) async {
    navigation.goTo(AppDestination.generation);
    await tester.pumpAndSettle();
    expect(find.byType(ConfigPageView), findsNothing);
    navigation.goTo(AppDestination.config);
    await tester.pumpAndSettle();
  }

  testWidgets('expanded prompt groups survive actual destination navigation',
      (tester) async {
    await mount(tester);
    expect(expanded(tester, 'First group'), isFalse);
    await toggle(tester, 'First group');
    await toggle(tester, 'Negative group');
    await leaveAndReturn(tester);
    expect(expanded(tester, 'First group'), isTrue);
    expect(expanded(tester, 'Second group'), isFalse);
    expect(expanded(tester, 'Negative group'), isTrue);
  });

  testWidgets('prompt groups survive parameter tab and parent collapse',
      (tester) async {
    await mount(tester);
    await toggle(tester, 'First group');
    await tester.tap(find.text(words['generation_parameters']));
    await tester.pumpAndSettle();
    await tester.tap(find.text(words['generation_prompt_config']));
    await tester.pumpAndSettle();
    expect(expanded(tester, 'First group'), isTrue);
    await toggle(tester, 'Base root');
    await toggle(tester, 'Base root');
    expect(expanded(tester, 'First group'), isTrue);
    await toggle(tester, 'First group');
    await leaveAndReturn(tester);
    expect(expanded(tester, 'First group'), isFalse);
  });

  testWidgets(
      'expansion follows config identity rather than list position or title',
      (tester) async {
    await mount(tester);
    await toggle(tester, 'First group');
    final children = payload.rootPromptConfig.prompts;
    children.insert(1, children.removeAt(0));
    payload.notifyListeners();
    await tester.pumpAndSettle();
    expect(expanded(tester, 'First group'), isTrue);
    expect(expanded(tester, 'Second group'), isFalse);
    await leaveAndReturn(tester);
    expect(expanded(tester, 'First group'), isTrue);
    children[1] = leaf('First group');
    payload.notifyListeners();
    await tester.pumpAndSettle();
    expect(expanded(tester, 'First group'), isFalse);
  });
}
