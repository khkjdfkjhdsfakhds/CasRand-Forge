import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_divider.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_editor.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';

class _CountingPromptEditingAssistance extends PromptEditingAssistance {
  _CountingPromptEditingAssistance({required Future<DanbooruTagIndex> index})
      : super(index: index);

  final List<String> requests = <String>[];

  @override
  Future<PromptCompletionResult> complete(PromptCompletionRequest request) {
    requests.add(request.text);
    return super.complete(request);
  }
}

void main() {
  Future<void> pumpEditor(
    WidgetTester tester, {
    required List<String> entries,
    required ValueChanged<List<String>> onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 700,
              child: PromptEntryEditor(
                initialEntries: entries,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextEditingController controllerFor(WidgetTester tester) {
    return tester
        .widget<TextField>(find.byKey(const Key('prompt-entry-editor')))
        .controller!;
  }

  testWidgets('all prompt entries share one plain text editing surface', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const [
        'red hair',
        '# private note',
        'blue eyes\n# keep this cool',
        '  ',
      ],
      onChanged: (_) {},
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(
      controllerFor(tester).text,
      'red hair\n# private note\nblue eyes\n# keep this cool\n  ',
    );
    final textField = tester.widget<TextField>(
      find.byKey(const Key('prompt-entry-editor')),
    );
    expect(textField.decoration?.border, isA<OutlineInputBorder>());
    expect(textField.decoration?.filled, isTrue);
    expect(find.text('1'), findsNothing);
    expect(find.text('Comment'), findsNothing);
  });

  testWidgets('entry dividers are visual only and keep plain text input', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one', 'two'],
      onChanged: (_) {},
    );

    final overlay = find.byKey(const Key('prompt-entry-divider-overlay'));
    expect(overlay, findsOneWidget);
    final ignorePointers = tester.widgetList<IgnorePointer>(
      find.ancestor(of: overlay, matching: find.byType(IgnorePointer)),
    );
    expect(ignorePointers.any((widget) => widget.ignoring), isTrue);
    expect(controllerFor(tester).text, 'one\ntwo');
    const painter = PromptEntryDividerPainter(Colors.black);
    expect(painter.hitTest(Offset.zero), isFalse);
    const extremeScalePainter = PromptEntryDividerPainter(
      Colors.black,
      verticalOffset: -100,
    );
    expect(extremeScalePainter.lineY(const Size(100, 2)), 0.5);
  });

  testWidgets(
      'cascade completion remaps later entry boundary before Control movement',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'canonical_tag', category: 0, postCount: 10),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 500,
            child: PromptEntryEditor(
              initialEntries: const ['ca', 'second, third'],
              promptAssistance: assistance,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorState = tester.state<PromptAssistedTextFieldState>(
      find.byType(PromptAssistedTextField),
    );
    final controller = tester
        .widget<TextField>(
          find.byKey(const Key('prompt-entry-editor')),
        )
        .controller!;
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 2);
    editorState.requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final candidate = find.byKey(
      const Key('prompt-assistance-candidate-canonical_tag'),
      skipOffstage: false,
    );
    expect(candidate, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, 'canonical_tag, \nsecond, third');
    expect(controller.selection, const TextSelection.collapsed(offset: 15));

    controller.selection = const TextSelection.collapsed(offset: 18);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.text, 'canonical_tag, \nthird, second');
  });

  testWidgets('completion popup floats without resizing its dialog',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates(
      List.generate(
        12,
        (index) => PromptTagCandidate(
          tag: 'candidate_long_tag_$index',
          category: 0,
          postCount: 10,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Dialog(
              child: SizedBox(
                width: 310,
                height: 230,
                child: PromptEntryEditor(
                  initialEntries: const ['candidate'],
                  promptAssistance: assistance,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorFinder = find.byKey(const Key('prompt-entry-editor'));
    final dialogFinder = find.byType(Dialog);
    final editorBefore = tester.getRect(editorFinder);
    final dialogBefore = tester.getRect(dialogFinder);
    final controller = tester.widget<TextField>(editorFinder).controller!;
    await tester.tap(editorFinder);
    controller.selection = const TextSelection.collapsed(offset: 9);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final popup = find.byKey(
      const Key('prompt-assistance-options'),
      skipOffstage: false,
    );
    expect(popup, findsOneWidget);
    final popupRect = tester.getRect(popup);
    final viewport = tester.getRect(find.byType(Overlay).first);
    final editorAfter = tester.getRect(editorFinder);
    final dialogAfter = tester.getRect(dialogFinder);

    // OverlayPortal keeps this surface out of the editor's layout.  The
    // editor and its containing dialog therefore retain their exact bounds.
    expect(editorAfter, editorBefore);
    expect(dialogAfter, dialogBefore);
    // The popup is intentionally allowed to overlap the editable surface;
    // only its layout bounds must stay independent from the dialog.
    expect(popupRect.top, lessThan(editorAfter.bottom));
    expect(popupRect.bottom, greaterThan(editorAfter.top));
    expect(popupRect.width, lessThanOrEqualTo(420));
    expect(popupRect.height, lessThanOrEqualTo(280));
    expect(popupRect.left, greaterThanOrEqualTo(viewport.left));
    expect(popupRect.top, greaterThanOrEqualTo(viewport.top));
    expect(popupRect.right, lessThanOrEqualTo(viewport.right));
    expect(popupRect.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(
      find.byKey(
        const Key('prompt-assistance-candidate-candidate_long_tag_0'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('caret move while completion loads invalidates the old result',
      (tester) async {
    final indexCompleter = Completer<DanbooruTagIndex>();
    final assistance = PromptEditingAssistance(index: indexCompleter.future);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptEntryEditor(
            initialEntries: const ['ca,bl'],
            promptAssistance: assistance,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorFinder = find.byKey(const Key('prompt-entry-editor'));
    final controller = tester.widget<TextField>(editorFinder).controller!;
    final state = tester.state<PromptAssistedTextFieldState>(
      find.byType(PromptAssistedTextField),
    );
    await tester.tap(editorFinder);
    controller.selection = const TextSelection.collapsed(offset: 5);
    state.requestCompletion();
    await tester.pump();
    expect(find.byKey(const Key('prompt-assistance-loading')), findsOneWidget);

    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pump();
    expect(
      find.byKey(
        const Key('prompt-assistance-candidate-bl_tag'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    indexCompleter.complete(
      DanbooruTagIndex([
        PromptTagCandidate(tag: 'ca_tag', category: 0, postCount: 10),
        PromptTagCandidate(tag: 'bl_tag', category: 0, postCount: 10),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(
        const Key('prompt-assistance-candidate-ca_tag'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('text edits start one completion request for the latest value',
      (tester) async {
    final indexCompleter = Completer<DanbooruTagIndex>();
    final assistance = _CountingPromptEditingAssistance(
      index: indexCompleter.future,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptAssistedTextField(
            fieldKey: const Key('counting-assisted-field'),
            initialValue: 'ca',
            assistance: assistance,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('counting-assisted-field'));
    await tester.tap(field);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.enterText(field, 'can');
    await tester.pump();

    // The controller listener invalidates the pending "ca" request, while
    // onChanged owns the single replacement request for "can".
    expect(assistance.requests, ['ca', 'can']);

    indexCompleter.complete(
      DanbooruTagIndex([
        PromptTagCandidate(tag: 'can_tag', category: 0, postCount: 10),
      ]),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(
        const Key('prompt-assistance-candidate-can_tag'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
  });

  testWidgets('completion popup opens upward at the viewport edge',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates(
      List.generate(
        8,
        (index) => PromptTagCandidate(
          tag: 'edge_candidate_$index',
          category: 0,
          postCount: 10,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 310,
              height: 180,
              child: PromptEntryEditor(
                initialEntries: const ['edge'],
                promptAssistance: assistance,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorFinder = find.byKey(const Key('prompt-entry-editor'));
    final controller = tester.widget<TextField>(editorFinder).controller!;
    await tester.tap(editorFinder);
    controller.selection = const TextSelection.collapsed(offset: 4);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final popup = find.byKey(
      const Key('prompt-assistance-options'),
      skipOffstage: false,
    );
    expect(popup, findsOneWidget);
    final popupRect = tester.getRect(popup);
    final editorRect = tester.getRect(editorFinder);
    final viewport = tester.getRect(find.byType(Overlay).first);
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: controller.selection.extentOffset),
    );
    final caretTop = editable.localToGlobal(caret.topLeft).dy;
    expect(
      popupRect.bottom,
      lessThanOrEqualTo(caretTop + 1),
      reason: 'popup=$popupRect editor=$editorRect caret=$caret',
    );
    expect(popupRect.top, greaterThanOrEqualTo(viewport.top));
    expect(popupRect.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(popupRect.height, lessThanOrEqualTo(280));
  });

  testWidgets('completion popup stays close to the active caret line',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'candidate_tag', category: 0, postCount: 10),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 310,
              height: 300,
              child: PromptEntryEditor(
                initialEntries: const ['first line\nca'],
                promptAssistance: assistance,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorFinder = find.byKey(const Key('prompt-entry-editor'));
    final controller = tester.widget<TextField>(editorFinder).controller!;
    await tester.tap(editorFinder);
    controller.selection = const TextSelection.collapsed(offset: 13);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: controller.selection.extentOffset),
    );
    final caretRect = Rect.fromPoints(
      editable.localToGlobal(caret.topLeft),
      editable.localToGlobal(caret.bottomRight),
    );
    final popupRect = tester.getRect(
      find.byKey(
        const Key('prompt-assistance-options'),
        skipOffstage: false,
      ),
    );
    final gap = popupRect.top >= caretRect.bottom
        ? popupRect.top - caretRect.bottom
        : caretRect.top - popupRect.bottom;
    expect(
      gap,
      lessThan(80),
      reason: 'caret=$caretRect popup=$popupRect',
    );
  });

  testWidgets(
      'dialog completion stays above the IME safe area and accepts taps',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'candidate_tag', category: 0, postCount: 10),
    ]);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox.shrink()),
      ),
    );
    final rootContext = tester.element(find.byType(Scaffold));
    showDialog<void>(
      context: rootContext,
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          viewInsets: const EdgeInsets.only(bottom: 220),
        ),
        child: AlertDialog(
          content: SizedBox(
            width: 310,
            height: 230,
            child: PromptEntryEditor(
              initialEntries: const ['ca'],
              promptAssistance: assistance,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorFinder = find.byKey(const Key('prompt-entry-editor'));
    final dialogFinder = find.byType(Dialog);
    final dialogBefore = tester.getRect(dialogFinder);
    final controller = tester.widget<TextField>(editorFinder).controller!;
    await tester.tap(editorFinder);
    controller.selection = const TextSelection.collapsed(offset: 2);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final popup = find.byKey(
      const Key('prompt-assistance-options'),
      skipOffstage: false,
    );
    final popupRect = tester.getRect(popup);
    final viewport = tester.getRect(find.byType(Overlay).first);
    expect(popupRect.bottom, lessThanOrEqualTo(viewport.bottom - 220 + 1));
    await tester.tap(
      find.byKey(
        const Key('prompt-assistance-candidate-candidate_tag'),
        skipOffstage: false,
      ),
    );
    await tester.pump();
    expect(controller.text, 'candidate_tag, ');
    expect(tester.getRect(dialogFinder), dialogBefore);
  });

  testWidgets('left pointer down accepts a candidate before focus is lost',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'candidate_tag', category: 0, postCount: 10),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: PromptAssistedTextField(
                fieldKey: const Key('pointer-down-completion-field'),
                initialValue: 'ca',
                minLines: 1,
                maxLines: 1,
                assistance: assistance,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('pointer-down-completion-field'));
    final controller = tester.widget<TextField>(field).controller!;
    await tester.tap(field);
    controller.selection = const TextSelection.collapsed(offset: 2);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final candidate = find.byKey(
      const Key('prompt-assistance-candidate-candidate_tag'),
      skipOffstage: false,
    );
    expect(candidate, findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(candidate),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.text, 'candidate_tag, ');

    await gesture.up();
    await tester.pump();
  });

  testWidgets('completion hides when IME leaves no safe popup viewport',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(300, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'candidate_tag', category: 0, postCount: 10),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(
              padding: EdgeInsets.only(top: 30),
              viewInsets: EdgeInsets.only(bottom: 180),
            ),
            child: PromptAssistedTextField(
              fieldKey: const Key('tiny-safe-area-field'),
              initialValue: 'ca',
              assistance: assistance,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('tiny-safe-area-field'));
    await tester.tap(field);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byKey(
        const Key('prompt-assistance-options'),
        skipOffstage: false,
      ),
      findsNothing,
    );
  });

  testWidgets(
      'focus transfer hides old completion and keeps its controller inert',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates([
      PromptTagCandidate(tag: 'candidate_tag', category: 0, postCount: 10),
    ]);
    const firstKey = Key('first-assisted-field');
    const secondKey = Key('second-focus-field');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 80,
                child: PromptAssistedTextField(
                  fieldKey: firstKey,
                  initialValue: 'ca',
                  minLines: 1,
                  maxLines: 1,
                  assistance: assistance,
                  onChanged: (_) {},
                ),
              ),
              const SizedBox(height: 180),
              const TextField(key: secondKey),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final firstField = find.byKey(firstKey);
    final firstController = tester.widget<TextField>(firstField).controller!;
    await tester.tap(firstField);
    firstController.selection = const TextSelection.collapsed(offset: 2);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('prompt-assistance-options')), findsOneWidget);

    await tester.tap(find.byKey(secondKey));
    await tester.pump();
    expect(find.byKey(const Key('prompt-assistance-options')), findsNothing);
    expect(firstController.text, 'ca');
    expect(
      tester
          .state<EditableTextState>(
            find.descendant(
              of: find.byKey(secondKey),
              matching: find.byType(EditableText),
            ),
          )
          .widget
          .focusNode
          .hasFocus,
      isTrue,
    );
    expect(
      find.byKey(
        const Key('prompt-assistance-candidate-candidate_tag'),
        skipOffstage: false,
      ),
      findsNothing,
    );
  });

  testWidgets('disposing the assisted field restores a supplied focus handler',
      (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    KeyEventResult handler(FocusNode _, KeyEvent __) {
      return KeyEventResult.ignored;
    }

    focusNode.onKeyEvent = handler;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptAssistedTextField(
            fieldKey: const Key('disposable-assisted-field'),
            focusNode: focusNode,
            initialValue: 'ca',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(identical(focusNode.onKeyEvent, handler), isFalse);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(identical(focusNode.onKeyEvent, handler), isTrue);
  });

  testWidgets('keyboard highlight scrolls the bounded candidate list',
      (tester) async {
    final assistance = PromptEditingAssistance.fromCandidates(
      List.generate(
        12,
        (index) => PromptTagCandidate(
          tag: 'candidate_${index.toString().padLeft(2, '0')}',
          category: 0,
          postCount: 10,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 310,
              height: 180,
              child: PromptEntryEditor(
                initialEntries: const ['candidate_'],
                promptAssistance: assistance,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final editorFinder = find.byKey(const Key('prompt-entry-editor'));
    final controller = tester.widget<TextField>(editorFinder).controller!;
    await tester.tap(editorFinder);
    controller.selection = const TextSelection.collapsed(offset: 10);
    tester
        .state<PromptAssistedTextFieldState>(
          find.byType(PromptAssistedTextField),
        )
        .requestCompletion();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    for (var index = 0; index < 7; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    final popupRect = tester.getRect(
      find.byKey(
        const Key('prompt-assistance-options'),
        skipOffstage: false,
      ),
    );
    final highlighted = tester.getRect(
      find.byKey(
        const Key('prompt-assistance-candidate-candidate_07'),
        skipOffstage: false,
      ),
    );
    expect(highlighted.top, greaterThanOrEqualTo(popupRect.top));
    expect(highlighted.bottom, lessThanOrEqualTo(popupRect.bottom));
  });

  testWidgets('supplied focus handler keeps Enter split and undo once',
      (tester) async {
    var entries = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptEntryEditor(
            initialEntries: const ['one two'],
            onChanged: (value) => entries = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TextField>(
          find.byKey(const Key('prompt-entry-editor')),
        )
        .controller!;
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(entries, ['one ', 'two']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(entries, ['one two']);
  });

  testWidgets('caret beside an entry boundary stays aligned with the text', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one', 'two'],
      onChanged: (_) {},
    );

    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final glyphBox = editable
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 3),
        )
        .first;
    final caret = editable.getLocalRectForCaret(
      const TextPosition(offset: 3),
    );

    expect(
      caret.top,
      greaterThanOrEqualTo(glyphBox.top - 1),
      reason: 'caret=$caret, glyph=$glyphBox',
    );
    expect(caret.bottom, lessThanOrEqualTo(glyphBox.bottom + 1));
    expect(
      caret.center.dy,
      closeTo((glyphBox.top + glyphBox.bottom) / 2, 2),
      reason: 'caret=$caret, glyph=$glyphBox',
    );
  });

  testWidgets('selecting across a divider adds no wide empty selection box', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one', 'two'],
      onChanged: (_) {},
    );

    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final boundaryBoxes = editable.getBoxesForSelection(
      const TextSelection(baseOffset: 3, extentOffset: 4),
    );

    expect(boundaryBoxes, isNotEmpty);
    expect(
      boundaryBoxes.every((box) => box.right - box.left <= 2),
      isTrue,
      reason: 'boundary selection boxes: $boundaryBoxes',
    );
  });

  testWidgets('divider spacing stays centered when text is scaled', (
    tester,
  ) async {
    final scalers = <TextScaler>[
      const TextScaler.linear(1.5),
      const TextScaler.linear(2),
      const _NonlinearTextScaler(),
    ];
    for (final textScaler in scalers) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              textScaler: textScaler,
            ),
            child: Scaffold(
              body: SizedBox(
                width: 640,
                height: 700,
                child: PromptEntryEditor(
                  initialEntries: const ['one', 'two'],
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final firstEntryCaret = editable.getLocalRectForCaret(
        const TextPosition(offset: 3, affinity: TextAffinity.upstream),
      );
      final secondEntryCaret = editable.getLocalRectForCaret(
        const TextPosition(offset: 4),
      );
      final dividerPaint =
          find.byKey(const Key('prompt-entry-divider-overlay'));
      final divider = tester.renderObject<RenderBox>(dividerPaint);
      final dynamic dividerPainter =
          tester.widget<CustomPaint>(dividerPaint).painter;
      final dividerY = divider
          .localToGlobal(
            Offset(0, dividerPainter.debugDividerYPositions.first as double),
          )
          .dy;
      final topGap =
          dividerY - editable.localToGlobal(firstEntryCaret.bottomLeft).dy;
      final bottomGap =
          editable.localToGlobal(secondEntryCaret.topLeft).dy - dividerY;

      expect(
        (topGap - bottomGap).abs(),
        lessThanOrEqualTo(1),
        reason: 'text scaler $textScaler, top=$topGap, bottom=$bottomGap',
      );
    }
  });

  testWidgets('vertical arrows cross a divider without an extra stop', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one', 'two'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 5));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 1));
  });

  testWidgets('vertical arrows preserve the visual column after soft wrapping',
      (
    tester,
  ) async {
    const firstEntry = 'abcdefghij klmnopqrst uvwxyz';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 150,
            height: 300,
            child: PromptEntryEditor(
              initialEntries: const [firstEntry, 'ABCDEFGHIJ'],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final controller = controllerFor(tester);
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    const beforeOffset = firstEntry.length - 2;
    controller.selection = const TextSelection.collapsed(offset: beforeOffset);
    final beforeX = editable
        .localToGlobal(
          editable
              .getLocalRectForCaret(
                const TextPosition(offset: beforeOffset),
              )
              .topLeft,
        )
        .dx;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    final afterOffset = controller.selection.extentOffset;
    final afterX = editable
        .localToGlobal(
          editable
              .getLocalRectForCaret(TextPosition(offset: afterOffset))
              .topLeft,
        )
        .dx;
    expect(afterOffset, greaterThan(firstEntry.length));
    expect(
      afterX,
      closeTo(beforeX, 2),
      reason: 'afterOffset=$afterOffset',
    );
  });

  testWidgets('vertical arrows traverse a leading empty entry', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['', 'two'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 0));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 1));
  });

  testWidgets('vertical arrows traverse a consecutive empty entry', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one', '', 'two'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 5));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 0));
  });

  testWidgets('Shift vertical arrows extend through an empty entry', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one', '', 'two'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection,
        const TextSelection(baseOffset: 1, extentOffset: 4));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection,
        const TextSelection(baseOffset: 1, extentOffset: 5));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection,
        const TextSelection(baseOffset: 1, extentOffset: 4));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  });

  testWidgets('arrow up reaches an entry trailing internal empty line', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one\n', 'two'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 6);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
  });

  testWidgets('Shift arrow up reaches the last of trailing internal lines', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one\n\n', 'two'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 7);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      controller.selection,
      const TextSelection(baseOffset: 7, extentOffset: 5),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  });

  testWidgets('repeated vertical arrows keep crossing entry dividers', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one', 'two', 'three'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 5));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 9));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  });

  testWidgets('Enter splits at the caret and Backspace merges the boundary', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['red hair'],
      onChanged: (value) => entries = value,
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(entries, ['red ', 'hair']);
    expect(controller.text, 'red \nhair');
    expect(controller.selection.baseOffset, 5);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(entries, ['red hair']);
    expect(controller.text, 'red hair');
    expect(controller.selection.baseOffset, 4);
  });

  testWidgets('Shift Enter inserts an internal newline without a divider', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['red hair'],
      onChanged: (value) => entries = value,
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(entries, ['red \nhair']);
    expect(controller.text, 'red \nhair');
  });

  testWidgets('deleting a boundary preserves an adjacent internal newline', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['one', '\ntwo'],
      onChanged: (value) => entries = value,
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(controller.text, 'one\ntwo');
    expect(entries, ['one\ntwo']);
  });

  testWidgets('select all can delete every entry in one operation', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['one', 'two', 'three'],
      onChanged: (value) => entries = value,
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(controller.text, isEmpty);
    expect(entries, ['']);
  });

  testWidgets('copying across entries returns only the plain text document', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpEditor(
      tester,
      entries: const ['one', 'two', 'three'],
      onChanged: (_) {},
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    final editableText = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    editableText.copySelection(SelectionChangedCause.keyboard);
    await tester.pump();

    expect(clipboardText, 'one\ntwo\nthree');
  });

  testWidgets('selection can replace text across entry boundaries', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['one', 'two', 'three'],
      onChanged: (value) => entries = value,
    );

    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'onXwo\nthree',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();

    expect(entries, ['onXwo', 'three']);
  });

  testWidgets('pasted newlines become entry boundaries', (tester) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['old'],
      onChanged: (value) => entries = value,
    );

    await tester.enterText(
      find.byKey(const Key('prompt-entry-editor')),
      'first\nsecond\nthird',
    );
    await tester.pumpAndSettle();

    expect(entries, ['first', 'second', 'third']);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('composing text can contain a newline without splitting', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const [''],
      onChanged: (value) => entries = value,
    );

    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '候\n',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();

    expect(entries, ['候\n']);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '候\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    expect(entries, ['候']);
  });

  testWidgets('IME candidate confirmation does not create an entry', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const [''],
      onChanged: (value) => entries = value,
    );

    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'hou',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '候\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pumpAndSettle();

    expect(entries, ['候']);
  });

  testWidgets('multiline paste during composition still creates entries', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const [''],
      onChanged: (value) => entries = value,
    );

    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'hou',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'first\nsecond',
        selection: TextSelection.collapsed(offset: 12),
      ),
    );
    await tester.pumpAndSettle();

    expect(entries, ['first', 'second']);
  });

  testWidgets('undo and redo restore entry boundaries', (tester) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['one two'],
      onChanged: (value) => entries = value,
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(entries, ['one ', 'two']);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(entries, ['one two']);
    expect(controller.selection.baseOffset, 4);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(entries, ['one ', 'two']);
  });

  testWidgets('large entry collections remain one editable document', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: List.generate(1000, (index) => 'entry $index'),
      onChanged: (_) {},
    );

    expect(find.byType(TextField), findsOneWidget);
    final lines = controllerFor(tester).text.split('\n');
    expect(lines, hasLength(1000));
    expect(lines.first, 'entry 0');
    expect(lines.last, 'entry 999');
  });

  testWidgets('scrolling a large prompt document keeps paint frames bounded', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: List.generate(
        3000,
        (index) => 'entry $index with enough text to exercise layout',
      ),
      onChanged: (_) {},
    );

    final overlayFinder = find.byKey(
      const Key('prompt-entry-divider-overlay'),
    );
    final overlayBefore = tester.widget<CustomPaint>(overlayFinder);
    final dynamic painterBefore = overlayBefore.painter;
    final int initialLayoutPassCount = painterBefore.debugLayoutPassCount;
    expect(initialLayoutPassCount, 1);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('prompt-entry-editor'))),
    );
    var worstFrame = Duration.zero;
    for (var frame = 0; frame < 12; frame++) {
      final stopwatch = Stopwatch()..start();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      stopwatch.stop();
      if (stopwatch.elapsed > worstFrame) worstFrame = stopwatch.elapsed;
    }
    await gesture.up();

    final overlayAfter = tester.widget<CustomPaint>(overlayFinder);
    final dynamic painterAfter = overlayAfter.painter;

    expect(worstFrame, lessThan(const Duration(milliseconds: 100)));
    expect(identical(painterBefore, painterAfter), isTrue);
    expect(painterAfter.debugLayoutPassCount, initialLayoutPassCount);
  });

  testWidgets(
      'Control arrow up/down adjusts weight without corrupting entry boundaries',
      (
    tester,
  ) async {
    List<String>? recordedEntries;
    await pumpEditor(
      tester,
      entries: const ['masterpiece', '1girl', 'solo'],
      onChanged: (entries) => recordedEntries = entries,
    );

    final controller = controllerFor(tester);
    await tester.tap(find.byKey(const Key('prompt-entry-editor')));
    await tester.pump();

    // Focus inside 'masterpiece' (entry 0)
    controller.selection = const TextSelection.collapsed(offset: 5);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(controller.text, '1.1::masterpiece::\n1girl\nsolo');
    expect(recordedEntries, ['1.1::masterpiece::', '1girl', 'solo']);

    // Focus inside '1girl' (entry 1) and increase weight twice
    controller.selection = const TextSelection.collapsed(offset: 23);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(controller.text, '1.1::masterpiece::\n1.2::1girl::\nsolo');
    expect(recordedEntries, ['1.1::masterpiece::', '1.2::1girl::', 'solo']);

    // Focus inside 'solo' (entry 2) and decrease weight
    controller.selection = const TextSelection.collapsed(offset: 36);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(controller.text, '1.1::masterpiece::\n1.2::1girl::\n0.9::solo::');
    expect(
        recordedEntries, ['1.1::masterpiece::', '1.2::1girl::', '0.9::solo::']);
  });
}

class _NonlinearTextScaler extends TextScaler {
  const _NonlinearTextScaler();

  @override
  double scale(double fontSize) =>
      fontSize <= 1 ? fontSize * 1.25 : fontSize * 2;

  @override
  // Only required by Flutter's backward-compatibility interface.
  double get textScaleFactor => 2;
}
