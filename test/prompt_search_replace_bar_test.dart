import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_editor.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_search_replace_bar.dart';
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

  group('PromptSearchReplaceBar unit & widget tests', () {
    testWidgets('hidden by default when visible is false', (tester) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptSearchReplaceBar(
              controller: controller,
              visible: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('prompt-search-replace-bar')), findsNothing);
      expect(find.byKey(const Key('prompt-search-replace-bar-hidden')), findsOneWidget);
    });

    testWidgets('shows controls and performs case-insensitive substring search', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'Cat and Dog and CAT and cat');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptSearchReplaceBar(
              controller: controller,
              visible: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('prompt-search-replace-bar')), findsOneWidget);
      expect(find.byKey(const Key('prompt-search-field')), findsOneWidget);
      expect(find.byKey(const Key('prompt-search-match-count')), findsOneWidget);

      final searchField = find.byKey(const Key('prompt-search-field'));
      await tester.enterText(searchField, 'cat');
      await tester.pump();

      expect(find.text('1/3'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 3));
    });

    testWidgets('searches special characters as literal substrings', (tester) async {
      final controller = TextEditingController(
        text: '{masterpiece}, (1girl:1.2), {masterpiece}, [lowres]',
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptSearchReplaceBar(
              controller: controller,
              visible: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final searchField = find.byKey(const Key('prompt-search-field'));
      await tester.enterText(searchField, '{masterpiece}');
      await tester.pump();

      expect(find.text('1/2'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 13));

      // Test parentheses and colon
      await tester.enterText(searchField, '(1girl:1.2)');
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 15, extentOffset: 26));
    });

    testWidgets('navigates next and previous matches with buttons and Enter/Shift+Enter', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'alpha beta alpha gamma alpha');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptSearchReplaceBar(
              controller: controller,
              visible: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final searchField = find.byKey(const Key('prompt-search-field'));
      await tester.enterText(searchField, 'alpha');
      await tester.pump();

      expect(find.text('1/3'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 5));

      // Next button
      await tester.tap(find.byKey(const Key('prompt-search-next')));
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 11, extentOffset: 16));

      // Enter in search field advances next
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('3/3'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 23, extentOffset: 28));

      // Wrap around on Enter
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 0, extentOffset: 5));

      // Previous button
      await tester.tap(find.byKey(const Key('prompt-search-prev')));
      await tester.pump();
      expect(find.text('3/3'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 23, extentOffset: 28));

      // Shift+Enter goes previous
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 11, extentOffset: 16));
    });

    testWidgets('toggles replace mode and replaces single match', (tester) async {
      final controller = TextEditingController(text: 'apple orange apple banana');
      addTearDown(controller.dispose);
      String? lastChanged;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptSearchReplaceBar(
              controller: controller,
              visible: true,
              onChanged: (val) => lastChanged = val,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('prompt-replace-field')), findsNothing);

      // Toggle replace
      await tester.tap(find.byKey(const Key('prompt-search-toggle-replace')));
      await tester.pump();

      expect(find.byKey(const Key('prompt-replace-field')), findsOneWidget);
      expect(find.byKey(const Key('prompt-search-replace-btn')), findsOneWidget);
      expect(find.byKey(const Key('prompt-search-replace-all-btn')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('prompt-search-field')), 'apple');
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('prompt-replace-field')), 'pear');
      await tester.pump();

      // Tap replace button
      await tester.tap(find.byKey(const Key('prompt-search-replace-btn')));
      await tester.pump();

      expect(controller.text, 'pear orange apple banana');
      expect(lastChanged, 'pear orange apple banana');
      expect(find.text('1/1'), findsOneWidget);
      expect(controller.selection, const TextSelection(baseOffset: 12, extentOffset: 17));

      // Enter in replace field replaces current and advances
      await tester.enterText(find.byKey(const Key('prompt-replace-field')), 'grape');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(controller.text, 'pear orange grape banana');
      expect(lastChanged, 'pear orange grape banana');
      expect(find.text('0/0'), findsOneWidget);
    });

    testWidgets('Replace All replaces all occurrences', (tester) async {
      final controller = TextEditingController(text: 'foo bar foo baz foo');
      addTearDown(controller.dispose);
      String? lastChanged;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptSearchReplaceBar(
              controller: controller,
              visible: true,
              initialReplaceMode: true,
              onChanged: (val) => lastChanged = val,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('prompt-search-field')), 'foo');
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('prompt-replace-field')), 'qux');
      await tester.pump();

      await tester.tap(find.byKey(const Key('prompt-search-replace-all-btn')));
      await tester.pump();

      expect(controller.text, 'qux bar qux baz qux');
      expect(lastChanged, 'qux bar qux baz qux');
      expect(find.text('0/0'), findsOneWidget);
    });

    testWidgets('Escape in search field and close button close search bar and restore focus', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'sample text');
      final editorFocus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(editorFocus.dispose);

      var closed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PromptSearchReplaceBar(
                  controller: controller,
                  focusNode: editorFocus,
                  visible: true,
                  onClose: () => closed = true,
                ),
                TextField(focusNode: editorFocus),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Press Escape in search field
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(closed, isTrue);
      expect(editorFocus.hasFocus, isTrue);

      closed = false;
      // Close button
      await tester.tap(find.byKey(const Key('prompt-search-close')));
      await tester.pump();
      expect(closed, isTrue);
    });

    testWidgets('auto-prefills search query from active selection when opened', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'prompt masterpiece tag');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection(baseOffset: 7, extentOffset: 18);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptSearchReplaceBar(
              controller: controller,
              visible: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final searchTextField = tester.widget<TextField>(
        find.byKey(const Key('prompt-search-field')),
      );
      expect(searchTextField.controller?.text, 'masterpiece');
      expect(find.text('1/1'), findsOneWidget);
    });
  });

  group('PromptEntryEditor search and replace integration', () {
    testWidgets('Cmd+F/Ctrl+F opens search bar and Enter replaces with boundary preservation', (
      tester,
    ) async {
      List<String> currentEntries = ['first entry', 'second entry', 'third entry'];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 500,
              child: PromptEntryEditor(
                initialEntries: currentEntries,
                onChanged: (val) => currentEntries = val,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('prompt-search-replace-bar')), findsNothing);

      // Focus editor
      await tester.tap(find.byKey(const Key('prompt-entry-editor')));
      await tester.pump();

      // Press Cmd+F / Ctrl+F
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      // Search bar is now visible
      expect(find.byKey(const Key('prompt-search-replace-bar')), findsOneWidget);

      // Search for 'entry'
      final searchField = find.byKey(const Key('prompt-search-field'));
      await tester.enterText(searchField, 'entry');
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);

      // Toggle replace mode
      await tester.tap(find.byKey(const Key('prompt-search-toggle-replace')));
      await tester.pump();

      final replaceField = find.byKey(const Key('prompt-replace-field'));
      await tester.enterText(replaceField, 'item');
      await tester.pump();

      // Replace All
      await tester.tap(find.byKey(const Key('prompt-search-replace-all-btn')));
      await tester.pump();

      expect(currentEntries, ['first item', 'second item', 'third item']);

      // Undo with Cmd+Z restores previous state
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(currentEntries, ['first entry', 'second entry', 'third entry']);
    });
  });

  group('PromptTabView fixed prompt search and replace integration', () {
    testWidgets('Cmd+F in fixed positive and negative prompt fields opens search and replaces text', (
      tester,
    ) async {
      final payload = PayloadConfig(
        rootPromptConfig: PromptConfig(strs: ['masterpiece, best quality'], prompts: []),
        negativePromptConfig: PromptConfig(strs: ['lowres, bad anatomy'], prompts: []),
        characterConfigList: [],
        savedPromptConfigList: [],
        paramConfig: ParamConfig(negativePrompt: 'initial'),
        settings: Settings.fromJson({}),
        overridePrompt: 'masterpiece, best quality',
        useOverridePrompt: true,
        useCharacterPromptWithOverride: false,
        promptMode: PromptMode.fixed,
      );

      final assistance = PromptEditingAssistance.fromCandidates([
        PromptTagCandidate(tag: 'masterpiece', category: 0, postCount: 100),
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
                viewmodel: PromptTabViewmodel(payloadConfig: payload),
                promptAssistance: assistance,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final positiveField = find.byKey(const Key('fixed-positive-prompt'));
      await tester.ensureVisible(positiveField);
      await tester.tap(positiveField);
      await tester.pump();

      // Trigger Cmd+F
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      final searchBars = find.byKey(const Key('prompt-search-replace-bar'));
      expect(searchBars, findsOneWidget);

      final searchField = find.byKey(const Key('prompt-search-field'));
      await tester.enterText(searchField, 'masterpiece');
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('prompt-search-toggle-replace')));
      await tester.pump();

      final replaceField = find.byKey(const Key('prompt-replace-field'));
      await tester.enterText(replaceField, 'masterwork');
      await tester.pump();

      await tester.tap(find.byKey(const Key('prompt-search-replace-btn')));
      await tester.pump();

      expect(payload.fixedProfile.rootPromptConfig.strs, ['masterwork, best quality']);
    });
  });
}
