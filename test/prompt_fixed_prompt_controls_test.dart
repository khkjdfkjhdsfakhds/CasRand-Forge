import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_weight_syntax.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';

List<TextSpan> leafTextSpans(TextSpan span) {
  final result = <TextSpan>[];
  if (span.text case final text? when text.isNotEmpty) result.add(span);
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) result.addAll(leafTextSpans(child));
  }
  return result;
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

  Future<void> pumpFixedPrompt(
    WidgetTester tester, {
    required PayloadConfig payload,
    required PromptEditingAssistance assistance,
  }) async {
    await EasyLocalization.ensureInitialized();
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
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
              promptAssistance: assistance,
            ),
          ),
        ),
      ),
    );
    // EasyLocalization starts loading its asset in a microtask.  Advance at
    // least one real frame before looking for fields, then settle the page.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    if (find
        .byKey(const Key('fixed-positive-prompt'), skipOffstage: false)
        .evaluate()
        .isEmpty) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
      'fixed negative prompt shares completion and both fixed fields apply Control shortcuts',
      (tester) async {
    final payload = PayloadConfig(
      rootPromptConfig: PromptConfig(strs: ['positive'], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(negativePrompt: 'initial'),
      settings: Settings.fromJson({}),
      overridePrompt: '1.2::legacy2::',
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
      promptMode: PromptMode.fixed,
    );
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'low_quality', category: 0, postCount: 100),
    ]);
    await pumpFixedPrompt(tester, payload: payload, assistance: assistance);

    final positive = find.byKey(
      const Key('fixed-positive-prompt'),
      skipOffstage: false,
    );
    final field = find.byKey(
      const Key('fixed-negative-prompt'),
      skipOffstage: false,
    );
    expect(field, findsOneWidget);
    expect(payload.fixedProfile.rootPromptConfig.strs, ['1.2::legacy2::']);
    await tester.ensureVisible(positive);
    await tester.tap(positive);
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pump();
    expect(payload.fixedProfile.rootPromptConfig.strs, ['1.2::legacy2 ::']);
    await tester.enterText(field, 'low_qu');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final candidate = find.byKey(
      const Key('prompt-assistance-candidate-low_quality'),
    );
    expect(candidate, findsOneWidget);
    await tester.tap(candidate);
    await tester.pump();

    expect(payload.fixedProfile.negativePromptConfig.strs, ['low_quality, ']);

    await tester.ensureVisible(positive);
    await tester.tap(positive);
    await tester.enterText(positive, 'one, two');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(payload.fixedProfile.rootPromptConfig.strs, ['one, 1.1::two::']);

    final negative = find.byKey(
      const Key('fixed-negative-prompt'),
      skipOffstage: false,
    );
    await tester.ensureVisible(negative);
    await tester.tap(negative);
    await tester.enterText(negative, 'bad, worse');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(payload.fixedProfile.negativePromptConfig.strs, ['worse, bad']);

    await tester.ensureVisible(positive);
    await tester.tap(positive);
    await tester.enterText(positive, '1.2::haku89::');
    await tester.pump();

    final textField = tester.widget<TextField>(positive);
    expect(textField.controller!.text, '1.2::haku89::');
    expect(payload.fixedProfile.rootPromptConfig.strs, ['1.2::haku89::']);
    var rendered = textField.controller!.buildTextSpan(
      context: tester.element(positive),
      withComposing: false,
    );
    var spans = leafTextSpans(rendered);
    expect(
      spans.any(
        (span) =>
            span.text == '1.2::haku89::' &&
            span.style?.backgroundColor ==
                PromptWeightSyntax.increaseBackground,
      ),
      isTrue,
    );
    expect(
      spans.any(
        (span) =>
            span.text == '::' &&
            span.style?.backgroundColor ==
                PromptWeightSyntax.delimiterBackground,
      ),
      isFalse,
    );

    await tester.ensureVisible(negative);
    await tester.tap(negative);
    await tester.pump();
    expect(textField.controller!.text, '1.2::haku89 ::');
    expect(payload.fixedProfile.rootPromptConfig.strs, ['1.2::haku89 ::']);
    rendered = textField.controller!.buildTextSpan(
      context: tester.element(positive),
      withComposing: false,
    );
    spans = leafTextSpans(rendered);
    expect(
      spans.any(
        (span) =>
            span.text == '::' &&
            span.style?.backgroundColor ==
                PromptWeightSyntax.delimiterBackground,
      ),
      isTrue,
    );

    await tester.ensureVisible(positive);
    await tester.tap(positive);
    await tester.enterText(positive, 'before');
    await tester.pump(const Duration(milliseconds: 600));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '1.2::paste89::',
        selection: TextSelection.collapsed(offset: 14),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(textField.controller!.text, '1.2::paste89::');

    final undoHistory = tester.state<UndoHistoryState<TextEditingValue>>(
      find.descendant(
        of: positive,
        matching: find.byType(UndoHistory<TextEditingValue>),
      ),
    );
    expect(undoHistory.canUndo, isTrue);
    undoHistory.undo();
    await tester.pump();
    expect(textField.controller!.text, 'before');

    expect(undoHistory.canRedo, isTrue);
    undoHistory.redo();
    await tester.pump();
    expect(textField.controller!.text, '1.2::paste89::');

    textField.controller!.value = const TextEditingValue(
      text: '1.2::ime89::',
      selection: TextSelection.collapsed(offset: 12),
      composing: TextRange(start: 5, end: 10),
    );
    await tester.pump();
    expect(textField.controller!.text, '1.2::ime89::');
    textField.controller!.value = const TextEditingValue(
      text: '1.2::ime89::',
      selection: TextSelection.collapsed(offset: 12),
    );
    await tester.pump();
    expect(textField.controller!.text, '1.2::ime89::');

    await tester.ensureVisible(negative);
    await tester.tap(negative);
    await tester.pump();
    expect(textField.controller!.text, '1.2::ime89 ::');
    final structuralField = positive;
    await tester.ensureVisible(structuralField);
    await tester.tap(structuralField);
    await tester.enterText(structuralField, 'one, 1.2::two, three::');
    await tester.pump();
    final structuralController =
        tester.widget<TextField>(structuralField).controller!;
    structuralController.selection =
        const TextSelection(baseOffset: 3, extentOffset: 0);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 600));
    expect(structuralController.text, '1.2::one, two, three::');
    expect(structuralController.selection,
        const TextSelection.collapsed(offset: 6));
    expect(
        tester.widget<TextField>(structuralField).focusNode!.hasFocus, isTrue);
    final structuralUndo = tester.state<UndoHistoryState<TextEditingValue>>(
        find.descendant(
            of: structuralField,
            matching: find.byType(UndoHistory<TextEditingValue>)));
    structuralUndo.undo();
    await tester.pump();
    expect(structuralController.text, 'one, 1.2::two, three::');
    structuralUndo.redo();
    await tester.pump();
    expect(structuralController.text, '1.2::one, two, three::');
  });
}
