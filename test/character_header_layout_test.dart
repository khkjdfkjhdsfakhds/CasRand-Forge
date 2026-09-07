import 'dart:convert';

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
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';

class _Loader extends AssetLoader {
  _Loader(this.words);
  final Map<String, dynamic> words;
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => words;
}

void main() {
  final translations = <String, Map<String, dynamic>>{};
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
    for (final lang in ['en', 'zh-CN']) {
      translations[lang] =
          jsonDecode(await rootBundle.loadString('assets/l10n/$lang.json'));
    }
  });

  PayloadConfig payload(PromptMode mode) => PayloadConfig(
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

  Future<void> mount(WidgetTester tester, PromptTabViewmodel vm,
      {double width = 1200, String lang = 'en'}) async {
    await tester.binding.setSurfaceSize(Size(width, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final locale = lang == 'en' ? const Locale('en') : const Locale('zh', 'CN');
    await tester.pumpWidget(EasyLocalization(
      supportedLocales: [locale],
      path: 'fixture',
      assetLoader: _Loader(translations[lang]!),
      startLocale: locale,
      saveLocale: false,
      child: Builder(
          builder: (context) => MaterialApp(
                locale: context.locale,
                supportedLocales: context.supportedLocales,
                localizationsDelegates: context.localizationDelegates,
                home: PromptTabView(
                    viewmodel: vm,
                    promptAssistance:
                        PromptEditingAssistance.fromCandidates([])),
              )),
    ));
    await tester.pumpAndSettle();
  }

  Finder section(PromptMode mode, int index) => find.byKey(Key(
      '${mode == PromptMode.fixed ? 'fixed-character' : 'character-prompt'}-section-$index'));
  Finder inside(PromptMode mode, int index, String key) =>
      find.descendant(of: section(mode, index), matching: find.byKey(Key(key)));
  Future<void> click(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  for (final mode in PromptMode.values) {
    for (final lang in ['en', 'zh-CN']) {
      for (final width in [390.0, 599.0, 600.0, 1200.0]) {
        testWidgets('$mode $lang width=$width two-row header geometry',
            (tester) async {
          final config = payload(mode);
          final vm = PromptTabViewmodel(payloadConfig: config);
          addTearDown(vm.dispose);
          vm.addCharacter();
          await mount(tester, vm, width: width, lang: lang);
          final header = inside(mode, 0, 'prompt-section-header');
          await tester.ensureVisible(header);
          final rect = tester.getRect(header);
          final actions = [
            'character-move-up',
            'character-move-down',
            'character-enabled-checkbox',
            'character-delete-button',
            'character-expand-button'
          ];
          double previousX = rect.left;
          for (final key in actions) {
            final control = inside(mode, 0, key);
            final controlRect = tester.getRect(control);
            final expectedSize = width >= 600 ? 48.0 : 40.0;
            expect(controlRect.width, closeTo(expectedSize, 0.1));
            expect(controlRect.height, closeTo(expectedSize, 0.1));
            if (key != actions.first) {
              expect(controlRect.left - previousX,
                  closeTo(width >= 600 ? 12 : 4, 0.1));
            }
            expect(rect.contains(controlRect.center), isTrue);
            expect(controlRect.left, greaterThanOrEqualTo(previousX));
            expect(controlRect.right, lessThanOrEqualTo(rect.right));
            previousX = controlRect.right;
          }
          final position =
              tester.getRect(inside(mode, 0, 'character-position-tile'));
          final gender =
              tester.getRect(inside(mode, 0, 'character-gender-tile'));
          expect(position.top, greaterThanOrEqualTo(rect.bottom));
          expect(gender.top, position.top);
          expect(position.width, closeTo(gender.width, 0.1));
          expect(position.right, closeTo(gender.left, 0.1));
          final detail = find.descendant(
              of: section(mode, 0), matching: find.byType(CharacterConfigView));
          expect(gender.right, closeTo(tester.getRect(detail).right, 0.1));
          expect(
              find.descendant(
                  of: detail,
                  matching:
                      find.byKey(const Key('character-enabled-checkbox'))),
              findsNothing);
          expect(
              find.descendant(
                  of: detail,
                  matching: find.byKey(const Key('character-delete-button'))),
              findsNothing);
          expect(
              tester
                  .widget<IconButton>(inside(mode, 0, 'character-move-up'))
                  .onPressed,
              isNull);
          expect(
              tester
                  .widget<IconButton>(inside(mode, 0, 'character-move-down'))
                  .onPressed,
              isNull);
          expect(
              find.descendant(
                  of: section(mode, 0),
                  matching: find.byIcon(Icons.delete_outline)),
              findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets(
        '$mode actions preserve identity and collapsed content across reorder',
        (tester) async {
      final config = payload(mode);
      final vm = PromptTabViewmodel(payloadConfig: config);
      addTearDown(vm.dispose);
      for (var i = 0; i < 3; i++) {
        vm.addCharacter();
        config.characterConfigList[i].positivePromptConfig.strs = [
          'positive-$i'
        ];
        config.characterConfigList[i].negativePromptConfig.strs = [
          'negative-$i'
        ];
      }
      final original = List<CharacterConfig>.of(config.characterConfigList);
      await mount(tester, vm);
      await click(tester, inside(mode, 1, 'character-enabled-checkbox'));
      expect(original[1].enabled, isFalse);
      await click(tester, inside(mode, 1, 'character-expand-button'));
      expect(inside(mode, 1, 'character-position-tile'), findsNothing);
      await click(tester, inside(mode, 1, 'character-move-up'));
      expect(
          config.characterConfigList, [original[1], original[0], original[2]]);
      expect(inside(mode, 0, 'character-position-tile'), findsNothing);
      expect(inside(mode, 1, 'character-position-tile'), findsOneWidget);
      expect(
          tester
              .widget<Checkbox>(inside(mode, 0, 'character-enabled-checkbox'))
              .value,
          isFalse);
      await click(tester, inside(mode, 0, 'character-move-down'));
      expect(config.characterConfigList, original);
      expect(inside(mode, 1, 'character-position-tile'), findsNothing);
      await click(tester, inside(mode, 1, 'character-expand-button'));
      expect(inside(mode, 1, 'character-position-tile'), findsOneWidget);
      expect(original[1].positivePromptConfig.strs, ['positive-1']);
      expect(original[1].negativePromptConfig.strs, ['negative-1']);
      await click(tester, inside(mode, 1, 'character-expand-button'));
      await click(tester, inside(mode, 1, 'character-delete-button'));
      expect(config.characterConfigList, [original[0], original[2]]);
      expect(inside(mode, 1, 'character-position-tile'), findsOneWidget);
      vm.addCharacter();
      await tester.pumpAndSettle();
      expect(inside(mode, 2, 'character-position-tile'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$mode position and gender dialogs still edit original fields',
        (tester) async {
      final config = payload(mode);
      final vm = PromptTabViewmodel(payloadConfig: config);
      addTearDown(vm.dispose);
      vm.addCharacter();
      await mount(tester, vm);
      await click(tester, inside(mode, 0, 'character-gender-tile'));
      await click(tester, find.byKey(const Key('character-gender-female')));
      expect(config.characterConfigList.single.gender,
          CharacterConfig.genderFemale);
      await click(tester, inside(mode, 0, 'character-position-tile'));
      expect(find.byKey(const Key('auto-position-checkbox')), findsOneWidget);
      await click(tester, find.byKey(const Key('auto-position-checkbox')));
      expect(config.paramConfig.autoPosition, isFalse);
      await click(tester, find.text('Confirm').last);
      expect(tester.takeException(), isNull);
    });
  }

  test('character name is optional, persistent and not prompt content', () {
    final character = CharacterConfig.fromEmpty();
    final legacy = character.toJson();
    expect(legacy.containsKey('name'), isFalse);
    expect(CharacterConfig.fromJson(legacy).name, '');
    for (final value in [null, 42, [], {}]) {
      expect(CharacterConfig.fromJson({...legacy, 'name': value}).name, '');
    }
    character.positivePromptConfig.strs = ['girl, blue hair'];
    character.name = '蓝发 / Alice 🐱';
    expect(CharacterConfig.fromJson(character.toJson()).name, character.name);
    expect(character.getPrompt().prompt.toPrompt(), 'girl, blue hair');
    character.name = '';
    expect(character.toJson().containsKey('name'), isFalse);
  });

  for (final mode in PromptMode.values) {
    for (final lang in ['en', 'zh-CN']) {
      testWidgets('$mode $lang inline names survive reorder clear and reload',
          (tester) async {
        final config = payload(mode);
        final vm = PromptTabViewmodel(payloadConfig: config);
        addTearDown(vm.dispose);
        vm.addCharacter();
        vm.addCharacter();
        final first = config.characterConfigList.first;
        final second = config.characterConfigList.last;
        await mount(tester, vm, width: 390, lang: lang);
        Finder field(int index) => inside(mode, index, 'character-name-field');
        final hint = lang == 'en' ? 'Character 1' : '角色 1';
        expect(tester.widget<TextField>(field(0)).decoration!.hintText, hint);
        await click(tester, field(0));
        expect(find.byType(AlertDialog), findsNothing);
        await tester.enterText(field(0), '蓝发 Alice 🐱');
        await tester.pump();
        expect(first.name, '蓝发 Alice 🐱');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await click(tester, inside(mode, 0, 'character-move-down'));
        expect(config.characterConfigList, [second, first]);
        expect(tester.widget<TextField>(field(1)).controller!.text, first.name);
        await click(tester, inside(mode, 1, 'character-expand-button'));
        await tester.enterText(field(1), 'Changed while collapsed');
        await tester.pumpAndSettle();
        final restored = PayloadConfig.fromJson(config.toJson());
        expect(restored.characterConfigList[1].name, first.name);
        expect(config.activeProfile.copy().characterConfigList[1].name,
            first.name);
        await tester.enterText(field(1), 'Long name ' * 40);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
            tester.getRect(field(1)).right,
            lessThanOrEqualTo(
                tester.getRect(inside(mode, 1, 'character-move-up')).left));
        await tester.enterText(field(1), '');
        await tester.pumpAndSettle();
        expect(first.name, '');
        expect(tester.widget<TextField>(field(1)).decoration!.hintText,
            lang == 'en' ? 'Character 2' : '角色 2');
        // A fresh model notification (such as an import) updates the editor.
        first.name = 'Restored label';
        vm.promptModeChanged();
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field(1)).controller!.text,
            'Restored label');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('names remain independent across modes and IME composition',
      (tester) async {
    final config = payload(PromptMode.random);
    final vm = PromptTabViewmodel(payloadConfig: config);
    addTearDown(vm.dispose);
    vm.addCharacter();
    await mount(tester, vm);
    final randomField = inside(PromptMode.random, 0, 'character-name-field');
    await click(tester, randomField);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'zhong',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 0, end: 5),
    ));
    await tester.pump();
    expect(tester.widget<TextField>(randomField).controller!.value.composing,
        const TextRange(start: 0, end: 5));
    await tester.enterText(randomField, '中文角色');
    config.switchPromptMode();
    vm.addCharacter();
    await tester.pumpAndSettle();
    final fixedField = inside(PromptMode.fixed, 0, 'character-name-field');
    expect(tester.widget<TextField>(fixedField).controller!.text, '');
    await tester.enterText(fixedField, 'Fixed label');
    config.switchPromptMode();
    vm.promptModeChanged();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(randomField).controller!.text, '中文角色');
    final restored = PayloadConfig.fromJson(config.toJson());
    expect(restored.randomProfile.characterConfigList.single.name, '中文角色');
    expect(
        restored.fixedProfile.characterConfigList.single.name, 'Fixed label');
    vm.removeCharacter(0);
    vm.addCharacter();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(randomField).controller!.text, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed state follows its profile when switching modes',
      (tester) async {
    final config = payload(PromptMode.random);
    final vm = PromptTabViewmodel(payloadConfig: config);
    addTearDown(vm.dispose);
    vm.addCharacter();
    await mount(tester, vm);
    await click(
        tester, inside(PromptMode.random, 0, 'character-expand-button'));
    config.switchPromptMode();
    vm.addCharacter();
    await tester.pumpAndSettle();
    expect(
        inside(PromptMode.fixed, 0, 'character-position-tile'), findsOneWidget);
    config.switchPromptMode();
    vm.promptModeChanged();
    await tester.pumpAndSettle();
    expect(
        inside(PromptMode.random, 0, 'character-position-tile'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
