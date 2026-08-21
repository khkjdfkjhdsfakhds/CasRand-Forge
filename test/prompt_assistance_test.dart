import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';

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

  test('bundled index decodes the pinned complete corpus', () async {
    final assistance = PromptEditingAssistance();
    final index = await assistance.ready;

    expect(index.length, 140782);
    expect(index.entries.first.tag, '1girl');
    expect(index.entries.first.category, 0);
    expect(index.entries.first.postCount, 6008644);
    expect(
      index.entries.map((entry) => entry.category).toSet(),
      containsAll(<int>{0, 1, 3, 4, 5}),
    );
    expect(index.search('high_res').first.tag, 'highres');
    expect(index.search('original_character').first.tag, 'original');

    final stopwatch = Stopwatch()..start();
    expect(index.search('blue'), isNotEmpty);
    expect(stopwatch.elapsedMilliseconds, lessThan(100));

    final wideQueryResults = index.search('in');
    expect(wideQueryResults, hasLength(12));
    expect(wideQueryResults.map((candidate) => candidate.tag).toSet(),
        hasLength(12));

    final continuousQueries = <String>[
      'in',
      'a_',
      're',
      'blue',
      'high',
      'character',
      'original_character',
    ];
    final continuousStopwatch = Stopwatch()..start();
    for (var iteration = 0; iteration < 12; iteration++) {
      for (final query in continuousQueries) {
        expect(index.search(query), hasLength(greaterThan(0)));
      }
    }
    continuousStopwatch.stop();
    expect(
      continuousStopwatch.elapsed,
      lessThan(const Duration(milliseconds: 100)),
    );
  });

  test('search ranks canonical and alias matches deterministically', () {
    final index = DanbooruTagIndex([
      PromptTagCandidate(
        tag: 'blue_hair',
        category: 0,
        postCount: 100,
        aliases: ['azure_hair'],
      ),
      PromptTagCandidate(
        tag: 'blue_eyes',
        category: 0,
        postCount: 200,
      ),
      PromptTagCandidate(
        tag: 'character_blue',
        category: 4,
        postCount: 900,
      ),
    ]);

    expect(index.search('blue').map((candidate) => candidate.tag), [
      'blue_eyes',
      'blue_hair',
      'character_blue',
    ]);
    expect(index.search('azure').single.tag, 'blue_hair');
    expect(index.search('BLUE HA').single.tag, 'blue_hair');
    expect(index.search('blue').length, 3);
  });

  test('completion resolves a fragment and preserves surrounding text',
      () async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(
        tag: 'cinemagraph',
        category: 0,
        postCount: 50,
      ),
    ]);
    const text = '1girl, cinem';
    final result = await assistance.complete(
      const PromptCompletionRequest(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );

    expect(result.query, 'cinem');
    expect(result.replacementRange, const TextRange(start: 7, end: 12));
    expect(result.candidates.single.displayTag, 'cinemagraph');
    final accepted = result.accept(result.candidates.single);
    expect(accepted.text, '1girl, cinemagraph, ');
    expect(
      accepted.selection,
      const TextSelection.collapsed(offset: '1girl, cinemagraph, '.length),
    );
  });

  test('completion resolves a fragment after Chinese comma', () async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(
        tag: 'cinemagraph',
        category: 0,
        postCount: 50,
      ),
    ]);
    const text = '1girl，cinem';
    final result = await assistance.complete(
      const PromptCompletionRequest(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );

    expect(result.query, 'cinem');
    expect(result.replacementRange, const TextRange(start: 6, end: 11));
    expect(result.candidates.single.displayTag, 'cinemagraph');
  });

  test('completion result rejects a stale caret or source value', () async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'blue_hair', category: 0, postCount: 1),
    ]);
    const text = 'one, blu';
    final result = await assistance.complete(
      const PromptCompletionRequest(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    expect(
        result.matches(
          const TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        ),
        isTrue);
    expect(
        result.matches(
          const TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: 1),
          ),
        ),
        isFalse);
    expect(
        result.matches(
          const TextEditingValue(
            text: 'one, blue_hair',
            selection: TextSelection.collapsed(offset: 14),
          ),
        ),
        isFalse);
    expect(
        result.matches(
          const TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
            composing: TextRange(start: 5, end: text.length),
          ),
        ),
        isFalse);
  });

  test('completion suppresses unsafe or non-tag contexts', () async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'blue_hair', category: 0, postCount: 1),
    ]);

    Future<PromptCompletionResult> complete(
      String text, {
      bool enabled = true,
      bool composing = false,
      TextSelection? selection,
    }) {
      return assistance.complete(
        PromptCompletionRequest(
          text: text,
          selection: selection ?? TextSelection.collapsed(offset: text.length),
          enabled: enabled,
          composing: composing,
        ),
      );
    }

    expect((await complete('b')).candidates, isEmpty);
    for (final numericFragment in <String>[
      '123',
      '1.',
      '.5',
      '+1',
      '-0.5',
      '+1.05',
    ]) {
      expect((await complete(numericFragment)).candidates, isEmpty);
    }
    expect((await complete('# blue_hair')).candidates, isEmpty);
    expect((await complete('__saved_config__')).candidates, isEmpty);
    expect((await complete('blue_hair', enabled: false)).candidates, isEmpty);
    expect((await complete('blue_hair', composing: true)).candidates, isEmpty);
    expect(
      (await complete(
        'blue_hair',
        selection: const TextSelection(baseOffset: 0, extentOffset: 2),
      ))
          .candidates,
      isEmpty,
    );
  });

  testWidgets('fixed positive prompt uses the shared completion adapter', (
    tester,
  ) async {
    final payload = PayloadConfig(
      rootPromptConfig: PromptConfig(strs: ['random'], prompts: []),
      negativePromptConfig: PromptConfig(strs: [], prompts: []),
      characterConfigList: [],
      savedPromptConfigList: [],
      paramConfig: ParamConfig(),
      settings: Settings.fromJson({}),
      overridePrompt: 'initial',
      useOverridePrompt: true,
      useCharacterPromptWithOverride: false,
      promptMode: PromptMode.fixed,
    );
    final viewmodel = PromptTabViewmodel(payloadConfig: payload);
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(
        tag: 'cinemagraph',
        category: 0,
        postCount: 50,
      ),
    ]);

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
              viewmodel: viewmodel,
              promptAssistance: assistance,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('fixed-positive-prompt'));
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.enterText(field, 'cinem');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    final candidate = find.byKey(
      const Key('prompt-assistance-candidate-cinemagraph'),
    );
    expect(candidate, findsOneWidget);
    await tester.tap(candidate);
    await tester.pumpAndSettle();

    expect(payload.fixedProfile.rootPromptConfig.strs, ['cinemagraph, ']);
  });
}
