import 'dart:async';
import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/ui/navigation/view_models/metadata_drop_area_viewmodel.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_dialog.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/settings_page/view_models/settings_page_viewmodel.dart';
import 'package:nai_casrand/ui/config_page/widgets/config_page_view.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_config_view.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_free_position_canvas.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_view.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';

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
  testWidgets('PR01 clipboard successful import uses informational icon',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.getData') {
        return {
          'text': jsonEncode(
              PromptConfig(strs: ['NEW_FIXTURE'], prompts: []).toJson())
        };
      }
      return null;
    });
    final config = PromptConfig(type: 'config', strs: [], prompts: []);
    await tester.pumpWidget(app(Scaffold(
        body: PromptConfigView(
            viewModel: PromptConfigViewModel(config: config)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.paste));
    await tester.pump();
    expect(config.prompts.single.strs, ['NEW_FIXTURE']);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
  });
  testWidgets(
      'PR02 actual model tab change shows correct character position editor',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    payload.fixedProfile.paramConfig
      ..model = 'nai-diffusion-5-full'
      ..autoPosition = false;
    payload.fixedProfile.characterConfigList.add(CharacterConfig.fromEmpty());
    await tester
        .pumpWidget(app(ConfigPageView(viewmodel: ConfigPageViewmodel())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fixed-positive-prompt')));
    await tester.pump();
    await tester.tap(find.text(words['generation_parameters']));
    await tester.pumpAndSettle();
    await tester.tap(find.text(words['generation_model']));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('nai-diffusion-4-5-full'));
    await tester.tap(find.text('nai-diffusion-4-5-full'));
    await tester.pumpAndSettle();
    expect(payload.paramConfig.model, 'nai-diffusion-4-5-full');
    await tester.tap(find.text(words['generation_prompt_config']));
    await tester.pumpAndSettle();
    final char =
        tester.widget<CharacterConfigView>(find.byType(CharacterConfigView));
    expect(char.viewmodel.isV5, false);
    await tester
        .ensureVisible(find.byKey(const Key('character-position-tile')));
    await tester.tap(find.byKey(const Key('character-position-tile')));
    await tester.pumpAndSettle();
    expect(find.byType(CharacterFreePositionCanvas), findsNothing);
  });
  testWidgets('CONTROL imported out of slider range steps remain renderable',
      (tester) async {
    final incoming = fixture('AFTER_FIXTURE');
    incoming.paramConfig.steps = 51;
    final vm = SettingsPageViewmodel(
        pickSettingsFile: () async =>
            SelectedSettingsFile(utf8.encode(jsonEncode(incoming.toJson()))));
    await tester.pumpWidget(app(const Scaffold(body: Text('IMPORT'))));
    await tester.pumpAndSettle();
    await vm.loadJsonConfig(tester.element(find.text('IMPORT')));
    await tester.pumpAndSettle();
    expect(configs.lastSaved, isNotNull,
        reason: 'Probe verifies actual import persisted candidate');
    expect(payload.paramConfig.steps, 51);
    await tester.pumpWidget(
        app(ParametersConfigView(viewmodel: ParametersConfigViewmodel())));
    await tester.pump();
    final error = tester.takeException();
    expect(error, isNull,
        reason:
            'SliderListTile clamps its presentation, so no crashing defect is inferred');
  });

  testWidgets('PR04 fixed character heading uses translated Character number',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    payload.fixedProfile.characterConfigList.add(CharacterConfig.fromEmpty());
    await tester
        .pumpWidget(app(ConfigPageView(viewmodel: ConfigPageViewmodel())));
    await tester.pumpAndSettle();
    expect(find.text('character 1'), findsNothing,
        reason: 'No untranslated character key should leak');
    expect(find.text('Character 1'), findsOneWidget,
        reason:
            'Should use existing character_number localization like random mode');
  });
  testWidgets(
      'CONTROL malformed clipboard import preserves existing prompt tree',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.getData') return {'text': '{"strs":[17]}'};
      return null;
    });
    await tester.pumpWidget(app(const Scaffold(body: Text('CLIPBOARD'))));
    await tester.pumpAndSettle();
    final config = PromptConfig(strs: [], prompts: [
      PromptConfig(strs: ['PRESERVE_FIXTURE'], prompts: [])
    ]);
    final before = jsonEncode(config.toJson());
    await PromptConfigViewModel(config: config)
        .importConfigFromClipboard(tester.element(find.text('CLIPBOARD')));
    await tester.pump();
    expect(jsonEncode(config.toJson()), before);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('PR05 import original prompt after editing refreshes fixed field',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(PromptTabView(
        viewmodel: PromptTabViewmodel(payloadConfig: payload),
        promptAssistance: PromptEditingAssistance.fromCandidates([]))));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('fixed-positive-prompt'));
    final edit =
        find.descendant(of: field, matching: find.byType(EditableText));
    await tester.enterText(field, 'USER_EDIT_FIXTURE');
    await tester.pump();
    expect(payload.overridePrompt, 'USER_EDIT_FIXTURE');
    unawaited(showImageImportDialog(tester.element(find.byType(PromptTabView)),
        candidate: ImageImportCandidate(
            bytes: Uint8List.fromList(
                img.encodePng(img.Image(width: 2, height: 2))),
            fileName: 'synthetic-original-prompt.png',
            prompt: 'BEFORE_FIXTURE',
            model: 'nai-diffusion-5-full',
            metadata: const {'steps': 28, 'prompt': 'BEFORE_FIXTURE'}),
        viewmodel: MetadataDropAreaViewmodel(payloadConfig: payload)));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('metadata-import-confirm')));
    await tester.tap(find.byKey(const Key('metadata-import-confirm')));
    await tester.pumpAndSettle();
    expect(payload.overridePrompt, 'BEFORE_FIXTURE');
    expect(tester.widget<EditableText>(edit).controller.text, 'BEFORE_FIXTURE',
        reason:
            'Import restores original A after user typed B, even if last widget initialValue was already A');
  });

  for (final negative in [false, true]) {
    for (final imported in ['BEFORE_FIXTURE', '']) {
      testWidgets(
          'fixed ${negative ? 'negative' : 'positive'} import resets edited text to "$imported"',
          (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 1700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final vm = PromptTabViewmodel(payloadConfig: payload);
        vm.setFixedPrompt('BEFORE_FIXTURE');
        vm.setFixedNegativePrompt('BEFORE_FIXTURE');
        await tester.pumpWidget(app(PromptTabView(
            viewmodel: vm,
            promptAssistance: PromptEditingAssistance.fromCandidates([]))));
        await tester.pumpAndSettle();
        final field = find.byKey(
            Key(negative ? 'fixed-negative-prompt' : 'fixed-positive-prompt'));
        final edit =
            find.descendant(of: field, matching: find.byType(EditableText));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'USER_EDIT_FIXTURE');
        await tester.pump();
        unawaited(showImageImportDialog(
            tester.element(find.byType(PromptTabView)),
            candidate: ImageImportCandidate(
                bytes: Uint8List.fromList(
                    img.encodePng(img.Image(width: 2, height: 2))),
                fileName: 'synthetic-prompt.png',
                prompt: imported,
                model: 'nai-diffusion-5-full',
                metadata: {'steps': 28, 'prompt': imported, 'uc': imported}),
            viewmodel: MetadataDropAreaViewmodel(payloadConfig: payload)));
        await tester.pumpAndSettle();
        await tester
            .ensureVisible(find.byKey(const Key('metadata-import-confirm')));
        await tester.tap(find.byKey(const Key('metadata-import-confirm')));
        await tester.pumpAndSettle();
        expect(tester.widget<EditableText>(edit).controller.text, imported);
        expect(negative ? vm.fixedNegativePromptText : vm.fixedPromptText,
            imported);
      });
    }
    testWidgets(
        'normal fixed ${negative ? 'negative' : 'positive'} rebuild keeps selection and composing',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final vm = PromptTabViewmodel(payloadConfig: payload);
      await tester.pumpWidget(app(PromptTabView(
          viewmodel: vm,
          promptAssistance: PromptEditingAssistance.fromCandidates([]))));
      await tester.pumpAndSettle();
      final field = find.byKey(
          Key(negative ? 'fixed-negative-prompt' : 'fixed-positive-prompt'));
      final edit =
          find.descendant(of: field, matching: find.byType(EditableText));
      await tester.ensureVisible(field);
      await tester.enterText(field, 'USER_EDIT_FIXTURE');
      await tester.pump();
      final controller = tester.widget<EditableText>(edit).controller;
      controller.value = controller.value.copyWith(
          selection: const TextSelection(baseOffset: 1, extentOffset: 4),
          composing: const TextRange(start: 0, end: 4));
      final before = controller.value;
      vm.promptModeChanged();
      await tester.pump();
      expect(controller.value, before);
      expect(tester.widget<EditableText>(edit).focusNode.hasFocus, isTrue);
    });
  }
}
