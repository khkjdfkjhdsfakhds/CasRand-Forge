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
import 'package:nai_casrand/ui/prompt_assistance/prompt_weight_syntax.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';
import 'package:nai_casrand/ui/saved_config_list/widgets/saved_config_list_view.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('all prompt-tab adapters reach the shared weighted preview', (
    tester,
  ) async {
    PromptConfig weighted(String comment) => PromptConfig(
          comment: comment,
          shuffled: false,
          strs: const ['1.2::haku89::'],
          prompts: [],
        );

    final base = weighted('base');
    final negative = weighted('negative');
    final nestedCharacterPositive = weighted('nested character positive');
    final characterPositive = PromptConfig(
      comment: 'character positive',
      type: 'config',
      strs: [],
      prompts: [nestedCharacterPositive],
    );
    final characterNegative = weighted('character negative');
    final saved = weighted('saved');
    final payload = PayloadConfig(
      rootPromptConfig: base,
      negativePromptConfig: negative,
      characterConfigList: [
        CharacterConfig(
          positions: const [Point<int>(3, 3)],
          positivePromptConfig: characterPositive,
          negativePromptConfig: characterNegative,
          gender: CharacterConfig.genderUnset,
          enabled: true,
        ),
      ],
      savedPromptConfigList: [saved],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: '',
      useOverridePrompt: false,
      useCharacterPromptWithOverride: false,
    );

    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/l10n',
        fallbackLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: PromptTabView(
              viewmodel: PromptTabViewmodel(payloadConfig: payload),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    await tester.tap(find.text('nested character positive'));
    await tester.pumpAndSettle();

    expect(
      find.byType(PromptWeightText, skipOffstage: false),
      findsNWidgets(4),
    );
    expect(base.strs.single, '1.2::haku89::');
    expect(negative.strs.single, '1.2::haku89::');
    expect(nestedCharacterPositive.strs.single, '1.2::haku89::');
    expect(characterNegative.strs.single, '1.2::haku89::');

    await tester.tap(find.byIcon(Icons.format_list_bulleted));
    await tester.pumpAndSettle();
    final savedPage = find.byType(SavedConfigListView);
    await tester.tap(
      find.descendant(of: savedPage, matching: find.text('saved')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: savedPage,
        matching: find.byType(PromptWeightText),
      ),
      findsOneWidget,
    );
    expect(saved.strs.single, '1.2::haku89::');
  });
}
