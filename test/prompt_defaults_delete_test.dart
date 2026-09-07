import 'dart:convert';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/character_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/character_config/widgets/character_config_view.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_config/view_models/prompt_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';
import 'package:nai_casrand/ui/saved_config_list/view_models/saved_config_list_viewmodel.dart';

class _Loader extends AssetLoader {
  final Map<String, dynamic> words;
  _Loader(this.words);
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => words;
}

PayloadConfig _payload(PromptMode mode) => PayloadConfig(
      rootPromptConfig: PromptConfig(strs: [], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({'prompt_autocomplete_enabled': false}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
      promptMode: mode,
    );

void main() {
  late Map<String, dynamic> words;
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

  Widget app(Widget child) => EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'fixture',
        assetLoader: _Loader(words),
        saveLocale: false,
        startLocale: const Locale('en'),
        child: Builder(
            builder: (context) => MaterialApp(
                  locale: context.locale,
                  supportedLocales: context.supportedLocales,
                  localizationsDelegates: context.localizationDelegates,
                  home: child,
                )),
      );

  void expectDefaults(PromptConfig config) {
    expect(config.selectionMethod, 'all');
    expect(config.shuffled, isFalse);
    expect(config.type, 'str');
  }

  test('new configs and nested children default to all ordered strings', () {
    final root = PromptConfig(strs: ['one', 'two', 'three'], prompts: []);
    expectDefaults(root);
    for (var i = 0; i < 20; i++) {
      expect(root.getPrmpts().toPrompt(), 'one, two, three');
    }
    final vm = PromptConfigViewModel(config: root);
    addTearDown(vm.dispose);
    vm.addNewConfig();
    expectDefaults(root.prompts.single);
    vm.config = root.prompts.single;
    vm.addNewConfig();
    expectDefaults(root.prompts.single.prompts.single);
    expectDefaults(PromptConfig.fromJson(root.toJson()));
  });

  test('explicit saved shuffle and manual coordinates survive roundtrip', () {
    final config =
        PromptConfig(shuffled: true, strs: ['one', 'two'], prompts: []);
    expect(PromptConfig.fromJson(config.toJson()).shuffled, isTrue);
    final payload = _payload(PromptMode.random);
    payload.paramConfig.autoPosition = false;
    payload.characterConfigList.add(CharacterConfig.fromEmpty()
      ..freeCenter = const Point<double>(0.2, 0.8));
    final restored = PayloadConfig.fromJson(payload.toJson());
    expect(restored.paramConfig.autoPosition, isFalse);
    expect(restored.characterConfigList.single.freeCenter,
        const Point<double>(0.2, 0.8));
  });

  testWidgets('saved-config creation also uses ordered strings',
      (tester) async {
    final vm = SavedConfigListViewmodel(configList: []);
    addTearDown(vm.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  onPressed: () => vm.addConfig(context),
                  child: const Text('add'),
                ))));
    await tester.tap(find.text('add'));
    expectDefaults(vm.configList.single);
  });

  for (final mode in PromptMode.values) {
    testWidgets(
        '$mode new character displays AI choice and keeps manual opt-in',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final payload = _payload(mode);
      final vm = PromptTabViewmodel(payloadConfig: payload);
      addTearDown(vm.dispose);
      vm.addCharacter();
      expect(payload.paramConfig.autoPosition, isTrue);
      expect(payload.characterConfigList.single.freeCenter, isNull);
      await tester.pumpWidget(app(PromptTabView(
          viewmodel: vm,
          promptAssistance: PromptEditingAssistance.fromCandidates([]))));
      await tester.pumpAndSettle();
      final tile = find.byKey(const Key('character-position-tile'));
      expect(find.descendant(of: tile, matching: find.text("AI's Choice")),
          findsOneWidget);
      expect(
          find.descendant(of: tile, matching: find.text('C3')), findsNothing);
      vm.setAutoPosition(false);
      await tester.pumpAndSettle();
      expect(
          find.descendant(of: tile, matching: find.text('C3')), findsOneWidget);
      vm.addCharacter();
      expect(payload.paramConfig.autoPosition, isFalse);
      vm.setAutoPosition(true);
      await tester.pumpAndSettle();
      expect(find.text("AI's Choice"), findsNWidgets(2));
    });

    testWidgets(
        '$mode inline x deletes only its character including disabled and last',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final payload = _payload(mode);
      final vm = PromptTabViewmodel(payloadConfig: payload);
      addTearDown(vm.dispose);
      for (var i = 0; i < 3; i++) {
        vm.addCharacter();
        payload.characterConfigList[i].positivePromptConfig.strs = [
          'character-$i'
        ];
        payload.characterConfigList[i].negativePromptConfig.strs = [
          'negative-$i'
        ];
      }
      final original = List<CharacterConfig>.of(payload.characterConfigList);
      original[1].enabled = false;
      final inactive = mode == PromptMode.fixed
          ? payload.randomProfile
          : payload.fixedProfile;
      final untouched = CharacterConfig.fromEmpty();
      inactive.characterConfigList.add(untouched);
      await tester.pumpWidget(app(PromptTabView(
          viewmodel: vm,
          promptAssistance: PromptEditingAssistance.fromCandidates([]))));
      await tester.pumpAndSettle();
      Finder buttonAt(int index) => find.descendant(
            of: find.byKey(Key(
                '${mode == PromptMode.fixed ? 'fixed-character' : 'character-prompt'}-section-$index')),
            matching: find.byKey(const Key('character-delete-button')),
          );
      expect(
          find.byKey(const Key('character-delete-button')), findsNWidgets(3));
      final checkbox = find.descendant(
          of: find.byKey(Key(
              '${mode == PromptMode.fixed ? 'fixed-character' : 'character-prompt'}-section-1')),
          matching: find.byKey(const Key('character-enabled-checkbox')));
      await tester.ensureVisible(buttonAt(1));
      expect(tester.getCenter(buttonAt(1)).dx,
          greaterThan(tester.getCenter(checkbox).dx));
      expect(tester.getCenter(buttonAt(1)).dy,
          closeTo(tester.getCenter(checkbox).dy, 1));
      await tester.tap(buttonAt(1));
      await tester.pumpAndSettle();
      expect(payload.characterConfigList, [original[0], original[2]]);
      expect(payload.characterConfigList.last.positivePromptConfig.strs,
          ['character-2']);
      expect(payload.characterConfigList.last.negativePromptConfig.strs,
          ['negative-2']);
      expect(inactive.characterConfigList, [untouched]);
      vm.reorderCharacterAdjusted(1, 0);
      await tester.pumpAndSettle();
      await tester.ensureVisible(buttonAt(0));
      await tester.tap(buttonAt(0));
      await tester.pumpAndSettle();
      expect(payload.characterConfigList, [original[0]]);
      await tester.ensureVisible(buttonAt(0));
      await tester.tap(buttonAt(0));
      await tester.pumpAndSettle();
      expect(payload.characterConfigList, isEmpty);
      expect(find.byType(CharacterConfigView), findsNothing);
      expect(PayloadConfig.fromJson(payload.toJson()).characterConfigList,
          isEmpty);
      vm.addCharacter();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('character-delete-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
