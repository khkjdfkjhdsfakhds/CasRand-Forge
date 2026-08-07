import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_editor.dart';

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
    expect(textField.decoration?.border, InputBorder.none);
    expect(find.text('1'), findsNothing);
    expect(find.text('Comment'), findsNothing);
  });

  testWidgets('entry dividers are visual only and ignore pointer input', (
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
}
