import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:nai_casrand/ui/navigation/widgets/navigation_view.dart';
import 'package:nai_casrand/ui/navigation/view_models/navigation_view_model.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'dart:io';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/settings_page_viewmodel.dart';
import 'package:nai_casrand/ui/settings_page/view_models/config_selection_page_viewmodel.dart';

PayloadConfig fixture(String prompt) => PayloadConfig(
      rootPromptConfig:
          PromptConfig(strs: [prompt], prompts: [], shuffled: false),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({
        'api_key': 'TOKEN_PRIMARY_FIXTURE',
        'api_tokens': [
          {
            'token': 'TOKEN_EXTRA_FIXTURE',
            'label': 'Extra fixture',
            'enabled': true,
            'is_primary': false
          }
        ],
        'parallel_api_enabled': true,
        'theme_mode': 'light'
      }),
      overridePrompt: prompt,
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
      promptMode: PromptMode.fixed,
    );

class MemoryConfigs extends ConfigService {
  bool failSave = false;
  Map<String, dynamic>? saved;
  Map<String, dynamic>? selected;
  MemoryConfigs() {
    currentUuid = 'LOCAL';
    configIndex = {
      'LOCAL': SavedConfigInfo(title: 'Fixture', lastModified: DateTime(2026))
    };
  }
  @override
  Future<void> saveConfig(Map<String, dynamic> data) async {
    if (failSave) throw StateError('FIXTURE_WRITE_FAILURE');
    saved = jsonDecode(jsonEncode(data));
  }

  @override
  Map<String, dynamic>? loadConfigByUuid(String uuid) => saved;
  @override
  Future<Map<String, dynamic>> selectConfig(String uuid,
          {Map<String, dynamic>? currentConfig}) async =>
      selected!;
}

class FailingImagePicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource(
          {required ImageSource source,
          ImagePickerOptions options = const ImagePickerOptions()}) async =>
      throw PlatformException(code: 'FIXTURE_PICKER_DENIED');
}

class CapturePicker extends FilePicker {
  final String path;
  final called = Completer<void>();
  CapturePicker(this.path);
  @override
  Future<String?> saveFile(
      {String? dialogTitle,
      String? fileName,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Uint8List? bytes,
      bool lockParentWindow = false}) async {
    if (!called.isCompleted) called.complete();
    return path;
  }
}

class LocalLoader extends AssetLoader {
  final Map<String, dynamic> words;
  LocalLoader(this.words);
  @override
  Future<Map<String, dynamic>> load(String p, Locale l) async => words;
}

class ExitHarness extends NavigationView {
  ExitHarness({super.key}) : super(viewModel: NavigationViewModel());
  @override
  NavigationViewState createState() => ExitHarnessState();
}

class ExitHarnessState extends NavigationViewState {
  // Only the visual/native-plugin shell is replaced; inherited lifecycle and exit callback run unchanged.
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('EXIT_HARNESS'));
}

void main() {
  late Map<String, dynamic> translations;
  late PayloadConfig payload;
  late MemoryConfigs service;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FilePicker.platform = CapturePicker('');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/shared_preferences'),
            (c) async => c.method == 'getAll' ? <String, Object>{} : true);
    await EasyLocalization.ensureInitialized();
    translations =
        jsonDecode(await rootBundle.loadString('assets/l10n/en.json'));
  });
  setUp(() async {
    await GetIt.I.reset();
    payload = fixture('BEFORE_FIXTURE');
    service = MemoryConfigs();
    GetIt.I.registerSingleton<PayloadConfig>(payload);
    GetIt.I.registerSingleton<ConfigService>(service);
  });
  tearDown(() async {
    await GetIt.I.reset();
  });
  Widget app(Widget child, {bool adaptive = false}) => EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'fixtures',
      assetLoader: LocalLoader(translations),
      saveLocale: false,
      startLocale: const Locale('en'),
      child: Builder(builder: (ctx) {
        Widget build(ThemeData? theme, ThemeData? dark) => MaterialApp(
            theme: theme,
            darkTheme: dark,
            locale: ctx.locale,
            supportedLocales: ctx.supportedLocales,
            localizationsDelegates: ctx.localizationDelegates,
            home: Scaffold(body: child));
        return adaptive
            ? AdaptiveTheme(
                light: ThemeData.light(),
                dark: ThemeData.dark(),
                initial: AdaptiveThemeMode.light,
                builder: build)
            : build(ThemeData.light(), null);
      }));
  Future<BuildContext> contextFor(WidgetTester tester,
      {bool adaptive = false}) async {
    await tester
        .pumpWidget(app(const Text('AUDIT_CONTEXT'), adaptive: adaptive));
    await tester.pumpAndSettle();
    return tester.element(find.text('AUDIT_CONTEXT'));
  }

  testWidgets('CFG-01 saved-config export must remove authentication',
      (tester) async {
    final ctx = await contextFor(tester);
    final dir = Directory.systemTemp.createTempSync('audit-export-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final previous = FilePicker.platform;
    final picker = CapturePicker('${dir.path}/fixture.json');
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = previous);
    service.saved = payload.toJson();
    final exported = await tester.runAsync(() async {
      ConfigSelectionPageViewmodel().saveConfigAsFile(ctx, 'LOCAL');
      await picker.called.future;
      final f = File(picker.path);
      for (var i = 0; i < 100; i++) {
        if (await f.exists() && await f.length() > 0) {
          return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      throw StateError('Export did not complete');
    });
    final settings = exported!['settings'] as Map<String, dynamic>;
    expect(settings.keys, isNot(contains('api_key')),
        reason: 'Shareable export must not include primary credential');
    expect(settings.keys, isNot(contains('api_tokens')));
  });
  testWidgets(
      'CFG-02 importing shareable settings preserves local authentication',
      (tester) async {
    final ctx = await contextFor(tester);
    final before = payload.settings.apiKey;
    final tokensBefore =
        jsonEncode(payload.settings.apiTokens.map((e) => e.toJson()).toList());
    final parallelBefore = payload.settings.parallelApiEnabled;
    final vm = SettingsPageViewmodel(
        pickSettingsFile: () async => SelectedSettingsFile(utf8
            .encode(jsonEncode(fixture('AFTER_FIXTURE').toShareableJson()))));
    await vm.loadJsonConfig(ctx);
    await tester.pump();
    expect(payload.overridePrompt, 'AFTER_FIXTURE');
    expect(payload.settings.apiKey, before,
        reason:
            'Real settings import must preserve this device authentication');
    expect((service.saved!['settings'] as Map)['api_key'], before);
    expect(
        jsonEncode(payload.settings.apiTokens.map((e) => e.toJson()).toList()),
        tokensBefore);
    expect(payload.settings.parallelApiEnabled, parallelBefore);
  });
  testWidgets('CFG-04 picker failure becomes visible controlled import failure',
      (tester) async {
    final ctx = await contextFor(tester);
    final vm = SettingsPageViewmodel(
        pickSettingsFile: () async =>
            throw const FileSystemException('FIXTURE_PICKER_ERROR'));
    await expectLater(vm.loadJsonConfig(ctx), completes);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });
  testWidgets('CFG-05 settings import applies theme to visible interface',
      (tester) async {
    final ctx = await contextFor(tester, adaptive: true);
    expect(Theme.of(ctx).brightness, Brightness.light);
    final incoming = fixture('AFTER_FIXTURE');
    incoming.settings.themeMode = 'dark';
    final vm = SettingsPageViewmodel(
        pickSettingsFile: () async =>
            SelectedSettingsFile(utf8.encode(jsonEncode(incoming.toJson()))));
    await vm.loadJsonConfig(ctx);
    await tester.pumpAndSettle();
    expect(payload.settings.themeMode, 'dark');
    expect(Theme.of(ctx).brightness, Brightness.dark);
  });
  test(
      'CONTROL shareable helper removes credentials and retains local tokens on import',
      () {
    final shared = fixture('AFTER_FIXTURE').toShareableJson();
    expect((shared['settings'] as Map).containsKey('api_key'), false);
    expect((shared['settings'] as Map).containsKey('api_tokens'), false);
    final before = payload.settings.apiKey;
    payload.loadShareableJson(shared);
    expect(payload.settings.apiKey, before);
    expect(payload.overridePrompt, 'AFTER_FIXTURE');
  });
  test('CFG-07 one malformed index entry must not hide healthy saved configs',
      () async {
    final dir = await Directory.systemTemp.createTemp('audit-index-');
    Hive.init(dir.path);
    final box = await Hive.openBox('index-fixture');
    try {
      await box.putAll({
        'savedUuid': 'A',
        'savedConfig-A': jsonEncode(fixture('A').toJson()),
        'savedConfig-B': jsonEncode(fixture('B').toJson()),
        'configIndex': jsonEncode({
          'A': {
            'title': 'Healthy A',
            'lastModified': '2026-09-01T00:00:00.000'
          },
          'B': {
            'title': 'Healthy B',
            'lastModified': '2026-09-02T00:00:00.000'
          },
          'DAMAGED': {'title': 17, 'lastModified': '2026-09-03T00:00:00.000'}
        })
      });
      final loaded = ConfigService();
      await loaded.loadSavedConfigFromBox(box);
      expect(box.containsKey('savedConfig-B'), true);
      expect(loaded.configIndex.keys, containsAll(['A', 'B']));
    } finally {
      await box.close();
      await dir.delete(recursive: true);
    }
  });
  testWidgets('settings import failure preserves current data and credentials',
      (tester) async {
    final ctx = await contextFor(tester);
    final before = jsonEncode(payload.toJson());
    service.failSave = true;
    final vm = SettingsPageViewmodel(
        pickSettingsFile: () async => SelectedSettingsFile(
            utf8.encode(jsonEncode(fixture('AFTER').toShareableJson()))));
    await vm.loadJsonConfig(ctx);
    await tester.pump();
    expect(jsonEncode(payload.toJson()), before);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('both configuration pickers cancel silently without changes',
      (tester) async {
    final ctx = await contextFor(tester);
    final before = jsonEncode(payload.toJson());
    await SettingsPageViewmodel(pickSettingsFile: () async => null)
        .loadJsonConfig(ctx);
    await ConfigSelectionPageViewmodel(pickConfigFile: () async => null)
        .importConfigFromFile(ctx);
    expect(jsonEncode(payload.toJson()), before);
    expect(service.saved, isNull);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
      'saved configuration picker failure is reported and preserves state',
      (tester) async {
    final ctx = await contextFor(tester);
    final before = jsonEncode(payload.toJson());
    await ConfigSelectionPageViewmodel(
            pickConfigFile: () async =>
                throw const FileSystemException('FIXTURE_PICKER_FAILURE'))
        .importConfigFromFile(ctx);
    await tester.pump();
    expect(jsonEncode(payload.toJson()), before);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets(
      'parameter metadata picker failure is caught and visibly reported',
      (tester) async {
    final old = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = FailingImagePicker();
    try {
      await tester.pumpWidget(
          app(ParametersConfigView(viewmodel: ParametersConfigViewmodel())));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(SnackBar), findsOneWidget);
    } finally {
      ImagePickerPlatform.instance = old;
    }
  });
  testWidgets(
      'CFG-06B actual app exit callback accepts exit without saving latest prompt',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('audit-real-exit-');
    late ConfigService real;
    payload.settings.welcomeMessageVersion = 'FIXTURE_VERSION';
    final box = await tester.runAsync(() async {
      Hive.init(dir.path);
      final b = await Hive.openBox('fixture');
      real = ConfigService()
        ..saveBox = b
        ..currentUuid = 'LOCAL'
        ..configIndex = {
          'LOCAL':
              SavedConfigInfo(title: 'Fixture', lastModified: DateTime(2026))
        }
        ..packageInfo = PackageInfo(
            appName: 'Fixture',
            packageName: 'fixture',
            version: 'FIXTURE_VERSION',
            buildNumber: '1');
      await real.saveConfig(payload.toJson());
      return b;
    });
    await GetIt.I.unregister<ConfigService>();
    GetIt.I.registerSingleton<ConfigService>(real);
    await tester.pumpWidget(app(ExitHarness()));
    await tester.pumpAndSettle();
    PromptTabViewmodel(payloadConfig: payload)
        .setFixedPrompt('UNSAVED_EDIT_FIXTURE');
    final state = tester.state<ExitHarnessState>(find.byType(ExitHarness));
    final outcome = await tester.runAsync(() => state.didRequestAppExit());
    expect(outcome, AppExitResponse.exit);
    final saved =
        PayloadConfig.fromJson(jsonDecode(box!.get('savedConfig-LOCAL')));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => box.close());
    dir.deleteSync(recursive: true);
    expect(saved.overridePrompt, 'UNSAVED_EDIT_FIXTURE');
  });

  testWidgets('failed exit snapshot keeps session and can be retried',
      (tester) async {
    payload.settings.welcomeMessageVersion = 'FIXTURE_VERSION';
    service.packageInfo = PackageInfo(
        appName: 'Fixture',
        packageName: 'fixture',
        version: 'FIXTURE_VERSION',
        buildNumber: '1');
    await tester.pumpWidget(app(ExitHarness()));
    await tester.pumpAndSettle();
    PromptTabViewmodel(payloadConfig: payload).setFixedPrompt('EXIT_EDIT');
    service.failSave = true;
    final state = tester.state<ExitHarnessState>(find.byType(ExitHarness));
    expect(
        await tester.runAsync(state.didRequestAppExit), AppExitResponse.cancel);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(payload.overridePrompt, 'EXIT_EDIT');
    service.failSave = false;
    expect(
        await tester.runAsync(state.didRequestAppExit), AppExitResponse.exit);
    expect(PayloadConfig.fromJson(service.saved!).overridePrompt, 'EXIT_EDIT');
    await tester.pumpWidget(const SizedBox());
  });
}
