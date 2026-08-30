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
    expect(textField.controller!.text, '1.2::haku89 ::');
    expect(payload.fixedProfile.rootPromptConfig.strs, ['1.2::haku89 ::']);
    final rendered = textField.controller!.buildTextSpan(
      context: tester.element(positive),
      withComposing: false,
    );
    final spans = leafTextSpans(rendered);
    expect(
      spans.any(
        (span) =>
            span.text == '1.2::haku89 ' &&
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
      isTrue,
    );
  });
}
