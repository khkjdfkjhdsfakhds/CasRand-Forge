import 'dart:async';
import 'dart:convert';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/settings_page_viewmodel.dart';
import 'package:nai_casrand/ui/settings_page/widgets/settings_page_view.dart';
import 'package:nai_casrand/ui/settings_page/widgets/config_selection_page_view.dart';

PayloadConfig fixture(String prompt) => PayloadConfig(
    rootPromptConfig: PromptConfig(strs: [prompt], prompts: []),
    negativePromptConfig: PromptConfig(strs: [], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(),
    settings: Settings.fromJson({
      'api_key': 'TOKEN_FIXTURE',
      'file_name_prefix_key': prompt,
      'theme_mode': 'light'
    }),
    overridePrompt: prompt,
    useOverridePrompt: true,
    useCharacterPromptWithOverride: false,
    promptMode: PromptMode.fixed);

class Loader extends AssetLoader {
  final Map<String, dynamic> words;
  Loader(this.words);
  @override
  Future<Map<String, dynamic>> load(String p, Locale l) async => words;
}

class DelayConfigService extends ConfigService {
  Completer<void>? selectionGate;
  Map<String, dynamic>? lastSaved;
  @override
  Future<void> saveConfig(Map<String, dynamic> data) async {
    lastSaved = jsonDecode(jsonEncode(data));
  }

  @override
  Future<void> flush() async {}
  @override
  Future<Map<String, dynamic>> selectConfig(String uuid,
      {Map<String, dynamic>? currentConfig}) async {
    final gate = selectionGate;
    if (gate != null) await gate.future;
    currentUuid = uuid;
    return fixture('AFTER_FIXTURE').toJson();
  }
}

void main() {
  late Map<String, dynamic> words;
  late PayloadConfig payload;
  late DelayConfigService configs;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/shared_preferences'),
            (c) async => c.method == 'getAll' ? <String, Object>{} : true);
    await EasyLocalization.ensureInitialized();
    words = jsonDecode(await rootBundle.loadString('assets/l10n/en.json'));
  });
  setUp(() async {
    await GetIt.I.reset();
    payload = fixture('BEFORE_FIXTURE');
    configs = DelayConfigService()
      ..currentUuid = 'A'
      ..configIndex = {
        'A': SavedConfigInfo(title: 'Fixture A', lastModified: DateTime(2026)),
        'B': SavedConfigInfo(title: 'Fixture B', lastModified: DateTime(2026))
      };
    GetIt.I.registerSingleton<PayloadConfig>(payload);
    GetIt.I.registerSingleton<ConfigService>(configs);
  });
  tearDown(() async {
    await GetIt.I.reset();
  });
  Widget app(Widget child) => EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'fixture',
      assetLoader: Loader(words),
      saveLocale: false,
      startLocale: const Locale('en'),
      child: Builder(
          builder: (context) => MaterialApp(
              locale: context.locale,
              supportedLocales: context.supportedLocales,
              localizationsDelegates: context.localizationDelegates,
              home: child)));
  testWidgets(
      'CFG03 actual saved route return updates settings subtitle after delayed read',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final vm = SettingsPageViewmodel();
    await tester.pumpWidget(app(SettingsPageView(viewmodel: vm)));
    await tester.pumpAndSettle();
    expect(find.text('BEFORE_FIXTURE'), findsOneWidget);
    await tester.ensureVisible(find.text(words['saved_config']));
    await tester.tap(find.text(words['saved_config']));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigSelectionPageView), findsOneWidget);
    configs.selectionGate = Completer<void>();
    await tester.longPress(find.text('Fixture B'));
    await tester.pumpAndSettle();
    expect(payload.settings.fileNamePrefixKey, 'BEFORE_FIXTURE');
    await tester.runAsync(() async {
      configs.selectionGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await configs.flush();
    });
    await tester.pumpAndSettle();
    expect(payload.settings.fileNamePrefixKey, 'AFTER_FIXTURE');
    await tester.pageBack();
    await tester.pumpAndSettle();
    final staleVisible = find.text('BEFORE_FIXTURE').evaluate().length;
    vm.refresh();
    await tester.pump();
    expect(find.text('AFTER_FIXTURE'), findsOneWidget,
        reason: 'Control manual refresh must expose new data');
    expect(staleVisible, 0,
        reason: 'After normal return settings were still BEFORE_FIXTURE');
  });
  testWidgets(
      'saved selection completion refreshes settings even after early back',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(SettingsPageView()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(words['saved_config']));
    await tester.tap(find.text(words['saved_config']));
    await tester.pumpAndSettle();
    configs.selectionGate = Completer<void>();
    await tester.longPress(find.text('Fixture B'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('BEFORE_FIXTURE'), findsOneWidget);
    await tester.runAsync(() async {
      configs.selectionGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    expect(payload.settings.fileNamePrefixKey, 'AFTER_FIXTURE');
    expect(find.text('AFTER_FIXTURE'), findsOneWidget);
    expect(find.text('BEFORE_FIXTURE'), findsNothing);
  });
}
