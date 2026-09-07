import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';

class _TestAssetLoader extends AssetLoader {
  const _TestAssetLoader(this.translations);

  final Map<String, dynamic> translations;

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async {
    return translations;
  }
}

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

  testWidgets(
      'fixed prompt fields start taller and grow with content until a cap',
      (tester) async {
    final translations = jsonDecode(
      File('assets/l10n/en.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final payload = PayloadConfig(
      rootPromptConfig: PromptConfig(strs: ['short'], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: 'short',
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
      promptMode: PromptMode.fixed,
    );

    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/l10n',
        fallbackLocale: const Locale('en'),
        assetLoader: _TestAssetLoader(translations),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: PromptTabView(
              viewmodel: PromptTabViewmodel(payloadConfig: payload),
              promptAssistance: PromptEditingAssistance.fromCandidates([
                PromptTagCandidate(
                  tag: 'motion_lines',
                  category: 0,
                  postCount: 10,
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    final positive = find.byKey(
      const Key('fixed-positive-prompt'),
      skipOffstage: false,
    );
    final negative = find.byKey(
      const Key('fixed-negative-prompt'),
      skipOffstage: false,
    );
    expect(positive, findsOneWidget);
    expect(negative, findsOneWidget);

    final positiveField = tester.widget<TextField>(positive);
    final negativeField = tester.widget<TextField>(negative);
    expect(positiveField.minLines, kFixedPromptFieldMinLines);
    expect(positiveField.maxLines, kFixedPromptFieldMaxLines);
    expect(negativeField.minLines, kFixedNegativePromptMinLines);
    expect(negativeField.maxLines, kFixedNegativePromptMaxLines);
    expect(
      tester.getSize(negative).height,
      lessThan(tester.getSize(positive).height),
    );

    final shortHeight = tester.getSize(positive).height;

    await tester.enterText(
      positive,
      List.generate(16, (index) => 'motion lines $index').join('\n'),
    );
    await tester.pump();
    final grownHeight = tester.getSize(positive).height;
    expect(grownHeight, greaterThan(shortHeight));

    await tester.enterText(
      positive,
      List.generate(40, (index) => 'motion lines $index').join('\n'),
    );
    await tester.pump();
    final cappedHeight = tester.getSize(positive).height;
    expect(cappedHeight, greaterThan(grownHeight));

    await tester.enterText(
      positive,
      List.generate(80, (index) => 'motion lines $index').join('\n'),
    );
    await tester.pump();
    expect(tester.getSize(positive).height, closeTo(cappedHeight, 1));
  });

  Future<void> pumpNestedPromptField(
    WidgetTester tester,
    ScrollController parentController,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            key: const Key('parent-scroll'),
            controller: parentController,
            child: Column(
              children: [
                PromptAssistedTextField(
                  fieldKey: const Key('nested-prompt-field'),
                  initialValue: List.generate(
                    80,
                    (index) => 'motion lines $index',
                  ).join('\n'),
                  onChanged: (_) {},
                  completionEnabled: false,
                  minLines: 10,
                  maxLines: 16,
                ),
                const SizedBox(height: 1600, child: Text('page tail')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
      'wheel over an unfocused prompt field still scrolls the parent page',
      (tester) async {
    final parentController = ScrollController();
    addTearDown(parentController.dispose);
    await pumpNestedPromptField(tester, parentController);

    expect(parentController.offset, 0);
    expect(parentController.position.maxScrollExtent, greaterThan(0));

    final field = find.byKey(const Key('nested-prompt-field'));
    final textField = tester.widget<TextField>(field);
    expect(textField.focusNode!.hasFocus, isFalse);
    expect(textField.scrollPhysics, isA<NeverScrollableScrollPhysics>());

    final fieldScrollable = find.descendant(
      of: field,
      matching: find.byType(Scrollable),
    );
    final fieldPosition =
        tester.state<ScrollableState>(fieldScrollable).position;

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(field),
        scrollDelta: const Offset(0, 400),
      ),
    );
    await tester.pump();

    expect(parentController.offset, greaterThan(0));
    expect(fieldPosition.pixels, 0);
  });

  testWidgets(
      'wheel over a focused prompt field stays in the field and stops at the bottom',
      (tester) async {
    final parentController = ScrollController();
    addTearDown(parentController.dispose);
    await pumpNestedPromptField(tester, parentController);

    final field = find.byKey(const Key('nested-prompt-field'));
    await tester.tap(field);
    await tester.pump();

    final textField = tester.widget<TextField>(field);
    expect(textField.focusNode!.hasFocus, isTrue);
    expect(textField.scrollPhysics, isNull);

    final fieldScrollable = find.descendant(
      of: field,
      matching: find.byType(Scrollable),
    );
    final fieldPosition =
        tester.state<ScrollableState>(fieldScrollable).position;
    expect(fieldPosition.maxScrollExtent, greaterThan(0));

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(field),
        scrollDelta: const Offset(0, 4000),
      ),
    );
    await tester.pump();

    expect(parentController.offset, 0);
    expect(fieldPosition.pixels, greaterThan(0));
    expect(fieldPosition.pixels, fieldPosition.maxScrollExtent);
  });
}
