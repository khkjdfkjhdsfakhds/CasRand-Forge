import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/core/constants/parameters.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/generation_profile.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/config_page/widgets/config_page_view.dart';
import 'package:nai_casrand/ui/core/widgets/medium_effort_notice.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_config_view.dart';

PromptConfig _prompt(String text, {String comment = 'root'}) => PromptConfig(
      comment: comment,
      shuffled: false,
      strs: [text],
      prompts: [],
    );

/// A configuration document written before prompt schemes existed.
Map<String, dynamic> _legacyJson() => {
      'prompt_config': _prompt('legacy positive').toJson(),
      'negative_prompt_config': _prompt('legacy negative').toJson(),
      'character_config': [CharacterConfig.fromEmpty().toJson()],
      'saved_config': [_prompt('saved', comment: 'shared').toJson()],
      'param_config': ParamConfig(steps: 17).toJson(),
      'settings': <String, dynamic>{},
      'generation_count': 7,
      'generation_interval': 3,
      'lock_to_all_combinations': true,
    };

PayloadConfig _twoSchemes() {
  final config = PayloadConfig.fromJson(_legacyJson());
  config.createPromptSchemeFromCurrent('测试用');
  config.rootPromptConfig = _prompt('test positive');
  config.negativePromptConfig = _prompt('test negative');
  config.characterConfigList = [];
  config.paramConfig.steps = 28;
  config.generationCount = 2;
  config.generationIntervalSec = 9;
  config.lockToAllCombinations = false;
  return config;
}

String _text(PromptConfig config) => config.strs.single;

class _TestAssetLoader extends AssetLoader {
  const _TestAssetLoader(this.translations);

  final Map<String, dynamic> translations;

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      translations;
}

class _NoNetworkGenerationPageViewmodel extends GenerationPageViewmodel {
  @override
  void nextCommand() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('model', () {
    test('a legacy document becomes one scheme with its content intact', () {
      final config = PayloadConfig.fromJson(_legacyJson());

      expect(config.promptSchemes.map((s) => s.name), ['方案 1']);
      expect(config.currentPromptSchemeIndex, 0);
      expect(_text(config.rootPromptConfig), 'legacy positive');
      expect(_text(config.negativePromptConfig), 'legacy negative');
      expect(config.characterConfigList, hasLength(1));
      expect(config.paramConfig.steps, 17);
      expect(config.generationCount, 7);
      expect(config.generationIntervalSec, 3);
      expect(config.lockToAllCombinations, isTrue);
      expect(config.savedPromptConfigList.single.comment, 'shared');
    });

    test('loadJson also migrates a legacy document', () {
      final config = _twoSchemes()..loadJson(_legacyJson());

      expect(config.promptSchemes.map((s) => s.name), ['方案 1']);
      expect(_text(config.rootPromptConfig), 'legacy positive');
    });

    test('a new scheme is an independent copy appended to the list', () {
      final config = PayloadConfig.fromJson(_legacyJson());
      config.createPromptSchemeFromCurrent('方案 2');
      config.selectPromptScheme(0);
      config.createPromptSchemeFromCurrent('方案 3');

      expect(
        config.promptSchemes.map((s) => s.name),
        ['方案 1', '方案 2', '方案 3'],
      );
      expect(config.currentPromptSchemeIndex, 2);
      expect(_text(config.rootPromptConfig), 'legacy positive');
      expect(config.paramConfig.steps, 17);

      config.rootPromptConfig.strs = ['changed'];
      config.paramConfig.steps = 5;
      config.characterConfigList.clear();
      config.selectPromptScheme(0);
      expect(_text(config.rootPromptConfig), 'legacy positive');
      expect(config.paramConfig.steps, 17);
      expect(config.characterConfigList, hasLength(1));
    });

    test('a new scheme can stay inactive', () {
      final config = _twoSchemes();
      config.createPromptSchemeFromCurrent('三', activate: false);

      expect(config.promptSchemes.last.name, '三');
      expect(config.currentPromptScheme.name, '测试用');
      expect(
        _text(config.promptSchemes.last.profile.rootPromptConfig),
        'test positive',
      );
    });

    test('moving a scheme keeps the current scheme current', () {
      final config = _twoSchemes();
      config.createPromptSchemeFromCurrent('三', activate: false);

      config.movePromptScheme(2, 0);
      expect(config.promptSchemes.map((s) => s.name), ['三', '方案 1', '测试用']);
      expect(config.currentPromptScheme.name, '测试用');
      expect(config.currentPromptSchemeIndex, 2);

      config.movePromptScheme(2, 1);
      expect(config.promptSchemes.map((s) => s.name), ['三', '测试用', '方案 1']);
      expect(config.currentPromptSchemeIndex, 1);
      expect(() => config.movePromptScheme(0, 3), throwsRangeError);
    });

    test('switching changes every per-scheme field and nothing shared', () {
      final config = _twoSchemes();
      var notified = 0;
      config.addListener(() => notified++);
      final saved = config.savedPromptConfigList;
      final vibes = config.vibeConfigListV4;

      config.selectPromptScheme(0);

      expect(notified, 1);
      expect(_text(config.rootPromptConfig), 'legacy positive');
      expect(_text(config.negativePromptConfig), 'legacy negative');
      expect(config.characterConfigList, hasLength(1));
      expect(config.paramConfig.steps, 17);
      expect(config.generationCount, 7);
      expect(config.settings.generationCount, 7);
      expect(config.generationIntervalSec, 3);
      expect(config.lockToAllCombinations, isTrue);
      expect(identical(config.savedPromptConfigList, saved), isTrue);
      expect(identical(config.vibeConfigListV4, vibes), isTrue);

      config.selectPromptScheme(1);
      expect(_text(config.rootPromptConfig), 'test positive');
      expect(_text(config.negativePromptConfig), 'test negative');
      expect(config.characterConfigList, isEmpty);
      expect(config.generationCount, 2);
      expect(config.settings.lockToAllCombinations, isFalse);
    });

    test('the fixed profile is not affected by scheme changes', () {
      final config = _twoSchemes();
      config.switchPromptMode();
      expect(config.promptMode, PromptMode.fixed);
      final fixed = config.activeProfile;

      config.selectPromptScheme(0);
      expect(identical(config.activeProfile, fixed), isTrue);
      expect(config.promptMode, PromptMode.fixed);

      final fixedSaved = config.fixedProfile.savedPromptConfigList;
      config.switchPromptMode();
      expect(
        identical(config.savedPromptConfigList, fixedSaved),
        isFalse,
      );
    });

    test('metadata import lands in fixed and leaves schemes untouched', () {
      final config = _twoSchemes();

      config.loadParamJson({'steps': 3, 'negative_prompt': 'from image'});

      expect(config.promptMode, PromptMode.fixed);
      expect(config.fixedProfile.paramConfig.steps, 3);
      expect(config.promptSchemes[0].profile.paramConfig.steps, 17);
      expect(config.promptSchemes[1].profile.paramConfig.steps, 28);
    });

    test('saved configs stay one shared list after every kind of change', () {
      final config = _twoSchemes();
      config.savedPromptConfigList.add(_prompt('later', comment: 'later'));
      config.selectPromptScheme(0);
      expect(config.savedPromptConfigList.map((c) => c.comment),
          ['shared', 'later']);

      final replacement = [_prompt('only', comment: 'only')];
      config.savedPromptConfigList = replacement;
      config.selectPromptScheme(1);
      expect(identical(config.savedPromptConfigList, replacement), isTrue);

      config.randomProfile = GenerationProfile.fromJson(_legacyJson());
      expect(identical(config.savedPromptConfigList, replacement), isTrue);
    });

    test('names are trimmed, required and unique', () {
      final config = _twoSchemes();

      expect(
          config.validatePromptSchemeName('  '), PromptSchemeNameError.empty);
      expect(config.validatePromptSchemeName(' 测试用 '),
          PromptSchemeNameError.duplicate);
      expect(config.validatePromptSchemeName('测试用', ignoreIndex: 1), isNull);
      expect(() => config.createPromptSchemeFromCurrent('测试用'),
          throwsArgumentError);
      expect(() => config.renamePromptScheme(0, ''), throwsArgumentError);

      config.renamePromptScheme(1, '  出图用 ');
      expect(config.promptSchemes[1].name, '出图用');
      expect(config.currentPromptSchemeIndex, 1);
    });

    test('the next default name skips names already taken', () {
      final config = PayloadConfig.fromJson(_legacyJson());
      config.createPromptSchemeFromCurrent('方案 2');
      config.renamePromptScheme(0, '方案 3');

      expect(config.nextPromptSchemeName(), '方案 4');
      expect(config.nextPromptSchemeName((n) => 'Scheme $n'), 'Scheme 3');
    });

    test('deleting keeps the right scheme selected and the last one stays', () {
      final config = _twoSchemes();
      config.createPromptSchemeFromCurrent('三');

      // Before the current one: the same scheme remains selected.
      config.deletePromptScheme(0);
      expect(config.currentPromptScheme.name, '三');

      // The selected last entry: the previous one becomes current.
      config.deletePromptScheme(1);
      expect(config.currentPromptScheme.name, '测试用');
      expect(config.settings.generationCount, 2);

      expect(() => config.deletePromptScheme(0), throwsStateError);
      expect(config.promptSchemes, hasLength(1));
    });

    test('every scheme resets its sequential state', () {
      final config = _twoSchemes();
      String next(GenerationProfile profile) =>
          profile.rootPromptConfig.getPrmpts(savedConfigs: const []).toPrompt();

      for (final scheme in config.promptSchemes) {
        scheme.profile.rootPromptConfig
          ..selectionMethod = 'single_sequential'
          ..strs = ['a', 'b', 'c'];
        expect(next(scheme.profile), 'a');
        expect(next(scheme.profile), 'b');
      }

      config.resetSequentialState();

      for (final scheme in config.promptSchemes) {
        expect(next(scheme.profile), 'a');
      }
    });
  });

  group('persistence', () {
    test('the top level is the current scheme so older versions can read it',
        () {
      final config = _twoSchemes();
      final json = config.toJson();

      expect(json['current_prompt_scheme'], 1);
      expect(json['param_config']['steps'], 28);
      expect(json['prompt_config']['strs'], ['test positive']);
      expect(json['generation_count'], 2);
      final entries = json['prompt_schemes'] as List;
      expect(entries[1], {'name': '测试用'});
      expect(entries[0]['name'], '方案 1');
      expect(entries[0]['prompt_config']['strs'], ['legacy positive']);
      expect(entries[0]['param_config']['steps'], 17);
      expect((entries[0] as Map).containsKey('saved_config'), isFalse);
      expect(json['saved_config'], hasLength(1));
    });

    void expectBothSchemes(PayloadConfig config) {
      expect(config.promptSchemes.map((s) => s.name), ['方案 1', '测试用']);
      expect(config.currentPromptSchemeIndex, 1);
      expect(_text(config.rootPromptConfig), 'test positive');
      expect(config.paramConfig.steps, 28);
      expect(config.settings.generationCount, 2);
      config.selectPromptScheme(0);
      expect(_text(config.rootPromptConfig), 'legacy positive');
      expect(_text(config.negativePromptConfig), 'legacy negative');
      expect(config.characterConfigList, hasLength(1));
      expect(config.paramConfig.steps, 17);
      expect(config.generationCount, 7);
      expect(config.lockToAllCombinations, isTrue);
      final saved = config.savedPromptConfigList;
      config.selectPromptScheme(1);
      expect(identical(config.savedPromptConfigList, saved), isTrue);
    }

    test('schemes survive fromJson through real JSON text', () {
      final text = jsonEncode(_twoSchemes().toJson());
      expectBothSchemes(PayloadConfig.fromJson(jsonDecode(text)));
    });

    test('schemes survive loadJson through real JSON text', () {
      final text = jsonEncode(_twoSchemes().toJson());
      expectBothSchemes(
        PayloadConfig.fromJson(_legacyJson())..loadJson(jsonDecode(text)),
      );
    });

    test('schemes survive a shareable export and import', () {
      final text = jsonEncode(_twoSchemes().toShareableJson());
      final target = PayloadConfig.fromJson(_legacyJson())
        ..settings.updatePrimaryApiKey('pst-local');
      target.loadShareableJson(jsonDecode(text));
      expectBothSchemes(target);
      expect(target.settings.apiKey, 'pst-local');
    });

    test('a damaged index or nameless entry cannot prevent loading', () {
      final json = jsonDecode(jsonEncode(_twoSchemes().toJson()))
          as Map<String, dynamic>;
      json['current_prompt_scheme'] = 99;
      (json['prompt_schemes'] as List)[0]['name'] = '  ';

      final config = PayloadConfig.fromJson(json);

      expect(config.currentPromptSchemeIndex, 1);
      expect(config.promptSchemes[0].name, '方案 1');
    });

    test('import validation rejects inconsistent scheme documents', () {
      Map<String, dynamic> valid() =>
          jsonDecode(jsonEncode(_twoSchemes().toJson()));
      final service = ConfigService();

      service.validateConfigJson(valid());
      service.validateConfigJson(_legacyJson());

      for (final (label, mutate) in <(String, void Function(Map))>[
        ('not a list', (json) => json['prompt_schemes'] = 'x'),
        ('empty', (json) => json['prompt_schemes'] = []),
        ('entry type', (json) => json['prompt_schemes'][0] = 3),
        ('index type', (json) => json['current_prompt_scheme'] = 'a'),
        ('index range', (json) => json['current_prompt_scheme'] = 2),
        ('no content', (json) => json['prompt_schemes'][0] = {'name': 'a'}),
      ]) {
        final json = valid();
        mutate(json);
        expect(
          () => service.validateConfigJson(json),
          throwsA(isA<ConfigValidationException>()),
          reason: label,
        );
      }
    });
  });

  group('scheme cards', () {
    late Map<String, dynamic> translations;
    late PayloadConfig config;

    setUpAll(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/shared_preferences'),
        (call) async => call.method == 'getAll' ? <String, Object>{} : true,
      );
      await EasyLocalization.ensureInitialized();
      translations =
          jsonDecode(await rootBundle.loadString('assets/l10n/en.json'))
              as Map<String, dynamic>;
    });

    setUp(() async {
      await GetIt.instance.reset();
      GetIt.instance.registerSingleton(CommandStatus());
      GetIt.instance.registerSingleton(NavigationRequest());
      // Current scheme: '测试用' (index 1); '方案 1' is inactive.
      config = _twoSchemes();
      GetIt.instance.registerSingleton(config);
      GetIt.instance.registerSingleton<GenerationPageViewmodel>(
        _NoNetworkGenerationPageViewmodel(),
      );
    });

    tearDown(() async => GetIt.instance.reset());

    Future<void> pumpPage(
      WidgetTester tester, {
      Size size = const Size(1200, 900),
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(EasyLocalization(
        key: UniqueKey(),
        supportedLocales: const [Locale('en')],
        path: 'test',
        assetLoader: _TestAssetLoader(translations),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        saveLocale: false,
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: ConfigPageView(viewmodel: ConfigPageViewmodel()),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Finder card(int index) => find.byKey(Key('prompt-scheme-card-$index'));
    Finder inCard(int index, Finder matching) =>
        find.descendant(of: card(index), matching: matching);
    Finder keyIn(int index, String key) => inCard(index, find.byKey(Key(key)));
    Finder rootText(int index, String text) =>
        inCard(index, find.textContaining(text));
    Switch activeSwitch(WidgetTester tester, int index) =>
        tester.widget<Switch>(keyIn(index, 'prompt-scheme-active-switch'));
    IconButton button(WidgetTester tester, int index, String key) =>
        tester.widget<IconButton>(keyIn(index, key));
    Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> expand(WidgetTester tester, int index) =>
        tapAndSettle(tester, keyIn(index, 'prompt-scheme-expand'));

    testWidgets('every scheme is listed and only the active one starts open',
        (tester) async {
      await pumpPage(tester);

      expect(card(0), findsOneWidget);
      expect(card(1), findsOneWidget);
      expect(rootText(1, 'test positive'), findsWidgets);
      // A collapsed card builds none of its content.
      expect(find.textContaining('legacy positive'), findsNothing);
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets('several schemes can be open at the same time', (tester) async {
      await pumpPage(tester);

      await expand(tester, 0);

      expect(rootText(0, 'legacy positive'), findsWidgets);
      expect(rootText(1, 'test positive'), findsWidgets);
      expect(find.byType(TabBar), findsNWidgets(2));
      expect(config.currentPromptSchemeIndex, 1);
    });

    testWidgets('tapping empty header space toggles the card', (tester) async {
      await pumpPage(tester);
      final header = keyIn(0, 'prompt-scheme-header');

      await tester.tapAt(tester.getCenter(header));
      await tester.pumpAndSettle();
      expect(rootText(0, 'legacy positive'), findsWidgets);

      await tester.tapAt(tester.getCenter(header));
      await tester.pumpAndSettle();
      expect(find.textContaining('legacy positive'), findsNothing);
    });

    testWidgets('an inactive card edits its own scheme only', (tester) async {
      await pumpPage(tester);
      await expand(tester, 0);
      final parameters = find.text('Generation Parameters');

      await tapAndSettle(tester, inCard(0, parameters));
      expect(rootText(0, ': 17'), findsWidgets);

      final varietyPlus =
          inCard(0, find.widgetWithText(CheckboxListTile, 'Variety+'));
      await tester.ensureVisible(varietyPlus);
      await tester.pumpAndSettle();
      final before = config.promptSchemes[0].profile.paramConfig.varietyPlus;
      final activeBefore = config.paramConfig.varietyPlus;
      await tapAndSettle(tester, varietyPlus);

      expect(
        config.promptSchemes[0].profile.paramConfig.varietyPlus,
        !before,
      );
      expect(config.paramConfig.varietyPlus, activeBefore);
      expect(config.currentPromptSchemeIndex, 1);
    });

    testWidgets('a tab shows on the first frame after the tap', (tester) async {
      await pumpPage(tester);
      final parameters = inCard(1, find.text('Generation Parameters'));
      final prompts = inCard(1, find.text('Prompt Config'));
      final stepsControl = inCard(
        1,
        find.byKey(const Key('sampling-steps-control')),
      );
      final base = inCard(1, find.byKey(const Key('base-prompt-section')));

      await tester.tap(parameters);
      await tester.pump(const Duration(milliseconds: 16));
      expect(stepsControl, findsOneWidget);
      expect(base, findsNothing);
      await tester.pumpAndSettle();

      await tester.tap(prompts);
      await tester.pump(const Duration(milliseconds: 16));
      expect(base, findsOneWidget);
      expect(stepsControl, findsNothing);
      await tester.pumpAndSettle();
    });

    testWidgets('switching tabs keeps the same elements mounted',
        (tester) async {
      await pumpPage(tester);
      final button = inCard(1, find.byType(PromptConfigSettingsButton)).first;
      final element = tester.element(button);

      await tapAndSettle(tester, inCard(1, find.text('Generation Parameters')));
      await tapAndSettle(tester, inCard(1, find.text('Prompt Config')));

      expect(tester.element(button), same(element));
    });

    testWidgets('changing the model refreshes the kept prompt tab',
        (tester) async {
      await pumpPage(tester);
      await tapAndSettle(
        tester,
        inCard(1, find.text('Generation Parameters')),
      );
      final view = tester.widget<ParametersConfigView>(
        inCard(1, find.byType(ParametersConfigView)),
      );

      view.viewmodel.setModel(v5FullMediumModel);
      await tester.pumpAndSettle();
      await tapAndSettle(tester, inCard(1, find.text('Prompt Config')));

      expect(find.byType(MediumEffortNotice), findsWidgets);
    });

    testWidgets('each card manages its own characters', (tester) async {
      await pumpPage(tester);
      await expand(tester, 0);

      await tapAndSettle(tester, keyIn(0, 'prompt-scheme-characters'));
      await tapAndSettle(
        tester,
        find.text(translations['add_character'] as String),
      );
      await tapAndSettle(tester, find.text('Confirm'));

      expect(config.promptSchemes[0].profile.characterConfigList, hasLength(2));
      expect(config.promptSchemes[1].profile.characterConfigList, isEmpty);
    });

    testWidgets('the switch activates one scheme and cannot turn it off',
        (tester) async {
      await pumpPage(tester);
      expect(activeSwitch(tester, 1).value, isTrue);
      expect(activeSwitch(tester, 0).value, isFalse);

      await tapAndSettle(tester, keyIn(0, 'prompt-scheme-active-switch'));
      expect(config.currentPromptSchemeIndex, 0);
      expect(activeSwitch(tester, 0).value, isTrue);
      expect(activeSwitch(tester, 1).value, isFalse);

      await tapAndSettle(tester, keyIn(0, 'prompt-scheme-active-switch'));
      expect(config.currentPromptSchemeIndex, 0);
      expect(activeSwitch(tester, 0).value, isTrue);
    });

    testWidgets('activating does not expand or collapse anything',
        (tester) async {
      await pumpPage(tester);

      await tapAndSettle(tester, keyIn(0, 'prompt-scheme-active-switch'));

      expect(find.textContaining('legacy positive'), findsNothing);
      expect(rootText(1, 'test positive'), findsWidgets);
    });

    testWidgets('new scheme copies the active one, closed and inactive',
        (tester) async {
      await pumpPage(tester);

      await tapAndSettle(tester, find.byKey(const Key('prompt-scheme-add')));

      expect(config.promptSchemes.last.name, 'Scheme 3');
      expect(config.currentPromptSchemeIndex, 1);
      expect(
        _text(config.promptSchemes.last.profile.rootPromptConfig),
        'test positive',
      );
      expect(card(2), findsOneWidget);
      expect(find.byType(TabBar), findsOneWidget);
    });

    testWidgets('renaming happens in place and keeps the card open',
        (tester) async {
      await pumpPage(tester);
      final field = keyIn(1, 'prompt-scheme-name-field');

      await tester.enterText(field, ' 出图用 ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(config.promptSchemes[1].name, '出图用');
      expect(rootText(1, 'test positive'), findsWidgets);
    });

    testWidgets('a duplicate or empty name is refused and restored',
        (tester) async {
      await pumpPage(tester);
      final field = keyIn(1, 'prompt-scheme-name-field');

      for (final bad in ['方案 1', '   ']) {
        await tester.enterText(field, bad);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(config.promptSchemes[1].name, '测试用');
        expect(tester.widget<TextField>(field).controller!.text, '测试用');
      }
    });

    testWidgets('moving swaps cards and keeps the active scheme',
        (tester) async {
      await pumpPage(tester);
      expect(button(tester, 0, 'prompt-scheme-move-up').onPressed, isNull);
      expect(button(tester, 1, 'prompt-scheme-move-down').onPressed, isNull);

      await tapAndSettle(tester, keyIn(1, 'prompt-scheme-move-up'));

      expect(config.promptSchemes.map((s) => s.name), ['测试用', '方案 1']);
      expect(config.currentPromptScheme.name, '测试用');
      expect(activeSwitch(tester, 0).value, isTrue);
      expect(rootText(0, 'test positive'), findsWidgets);
    });

    testWidgets('delete asks first and the last scheme cannot be deleted',
        (tester) async {
      await pumpPage(tester);

      await tapAndSettle(tester, keyIn(1, 'prompt-scheme-delete'));
      expect(
        find.textContaining(
          translations['prompt_scheme_delete_active_note'] as String,
        ),
        findsOneWidget,
      );
      await tapAndSettle(tester, find.text('Cancel'));
      expect(config.promptSchemes, hasLength(2));

      await tapAndSettle(tester, keyIn(1, 'prompt-scheme-delete'));
      await tapAndSettle(
        tester,
        find.byKey(const Key('prompt-scheme-delete-confirm')),
      );

      expect(config.promptSchemes.map((s) => s.name), ['方案 1']);
      expect(config.currentPromptSchemeIndex, 0);
      expect(button(tester, 0, 'prompt-scheme-delete').onPressed, isNull);
    });

    testWidgets('generation locks scheme changes until it ends',
        (tester) async {
      await pumpPage(tester);
      final active = GetIt.I<CommandStatus>().isGenerationActive;
      final add = find.byKey(const Key('prompt-scheme-add'));
      OutlinedButton addButton() => tester.widget<OutlinedButton>(add);

      active.value = true;
      await tester.pump();
      expect(activeSwitch(tester, 0).onChanged, isNull);
      expect(addButton().onPressed, isNull);
      expect(button(tester, 0, 'prompt-scheme-delete').onPressed, isNull);
      expect(button(tester, 1, 'prompt-scheme-move-up').onPressed, isNull);
      expect(
        tester.widget<TextField>(keyIn(0, 'prompt-scheme-name-field')).readOnly,
        isTrue,
      );
      // Looking at another scheme is still allowed.
      expect(button(tester, 0, 'prompt-scheme-expand').onPressed, isNotNull);

      active.value = false;
      await tester.pump();
      expect(activeSwitch(tester, 0).onChanged, isNotNull);
      expect(addButton().onPressed, isNotNull);
    });

    testWidgets('stopping still counts as generating', (tester) async {
      await pumpPage(tester);

      GetIt.I<CommandStatus>().isStopping.value = true;
      await tester.pump();

      expect(activeSwitch(tester, 0).onChanged, isNull);
      GetIt.I<CommandStatus>().isStopping.value = false;
    });

    testWidgets('fixed mode shows its own tabs instead of the cards',
        (tester) async {
      await pumpPage(tester);

      config.switchPromptMode();
      await tester.pumpAndSettle();

      expect(card(0), findsNothing);
      expect(find.byKey(const Key('prompt-scheme-add')), findsNothing);
      expect(find.text('Generation Parameters'), findsOneWidget);
      expect(find.byKey(const Key('fixed-positive-prompt')), findsOneWidget);

      config.switchPromptMode();
      await tester.pumpAndSettle();
      expect(card(1), findsOneWidget);
      expect(rootText(1, 'test positive'), findsWidgets);
    });

    testWidgets('open cards survive a configuration reload', (tester) async {
      await pumpPage(tester);
      await expand(tester, 0);

      config.loadJson(jsonDecode(jsonEncode(config.toJson())));
      config.notifyExternalChange();
      await tester.pumpAndSettle();

      expect(rootText(0, 'legacy positive'), findsWidgets);
      expect(rootText(1, 'test positive'), findsWidgets);
    });

    testWidgets('phone width folds the actions into a menu', (tester) async {
      config.renamePromptScheme(1, '很长的方案名称' * 30);
      await pumpPage(tester, size: const Size(360, 700));

      expect(tester.takeException(), isNull);
      expect(keyIn(1, 'prompt-scheme-delete'), findsNothing);
      expect(keyIn(1, 'prompt-scheme-more'), findsOneWidget);
      expect(keyIn(0, 'prompt-scheme-active-badge'), findsNothing);
      expect(keyIn(1, 'prompt-scheme-active-badge'), findsOneWidget);

      await tapAndSettle(tester, keyIn(1, 'prompt-scheme-more'));
      await tapAndSettle(
          tester, find.byKey(const Key('prompt-scheme-move-up')));

      expect(config.currentPromptSchemeIndex, 0);
    });

    testWidgets(
        'the active badge appears only on the active card at full width',
        (tester) async {
      await pumpPage(tester);

      expect(keyIn(1, 'prompt-scheme-active-badge'), findsOneWidget);
      expect(keyIn(0, 'prompt-scheme-active-badge'), findsNothing);
    });
  });
}
