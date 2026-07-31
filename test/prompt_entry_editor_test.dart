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

  TextEditingController controllerFor(WidgetTester tester, int index) {
    return tester
        .widget<TextField>(
          find.byKey(Key('prompt-entry-field-$index')),
        )
        .controller!;
  }

  testWidgets('text fields alone distinguish prompt entries', (
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

    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsNothing);
    expect(find.text('Comment'), findsNothing);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('Enter splits at the caret and Backspace merges at the boundary',
      (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['red hair'],
      onChanged: (value) => entries = value,
    );

    final first = controllerFor(tester, 0);
    await tester.tap(find.byKey(const Key('prompt-entry-field-0')));
    first.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(entries, ['red ', 'hair']);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(controllerFor(tester, 1).selection.baseOffset, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(entries, ['red hair']);
    expect(find.byType(TextField), findsOneWidget);
    expect(controllerFor(tester, 0).selection.baseOffset, 4);
  });

  testWidgets('Shift Enter inserts an internal newline', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['red hair'],
      onChanged: (value) => entries = value,
    );

    final first = controllerFor(tester, 0);
    await tester.tap(find.byKey(const Key('prompt-entry-field-0')));
    first.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(entries, ['red \nhair']);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('editor omits help and touch action chrome', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      entries: const ['one'],
      onChanged: (_) {},
    );

    expect(find.byKey(const Key('prompt-entry-help')), findsNothing);
    expect(find.byKey(const Key('insert-prompt-line-break')), findsNothing);
    expect(find.byKey(const Key('next-prompt-entry')), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('pasted newlines become entry boundaries', (tester) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['old'],
      onChanged: (value) => entries = value,
    );

    await tester.enterText(
      find.byKey(const Key('prompt-entry-field-0')),
      'first\nsecond\nthird',
    );
    await tester.pumpAndSettle();

    expect(entries, ['first', 'second', 'third']);
    expect(find.byType(TextField), findsNWidgets(3));
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

    await tester.tap(find.byKey(const Key('prompt-entry-field-0')));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '候\n',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();

    expect(entries, ['候\n']);
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '候\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    expect(entries, ['候']);
    expect(find.byType(TextField), findsOneWidget);
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

    await tester.tap(find.byKey(const Key('prompt-entry-field-0')));
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
    expect(find.byType(TextField), findsOneWidget);
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

    await tester.tap(find.byKey(const Key('prompt-entry-field-0')));
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
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('trailing newline paste during composition keeps the boundary', (
    tester,
  ) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const [''],
      onChanged: (value) => entries = value,
    );

    await tester.tap(find.byKey(const Key('prompt-entry-field-0')));
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
        text: 'first\n',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pumpAndSettle();

    expect(entries, ['first', '']);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('undo and redo restore structural edits', (tester) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: const ['one two'],
      onChanged: (value) => entries = value,
    );

    final first = controllerFor(tester, 0);
    await tester.tap(find.byKey(const Key('prompt-entry-field-0')));
    first.selection = const TextSelection.collapsed(offset: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(entries, ['one ', 'two']);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(entries, ['one two']);
    expect(controllerFor(tester, 0).selection.baseOffset, 4);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(entries, ['one ', 'two']);
  });

  testWidgets('large entry lists remain lazy and editable', (tester) async {
    var entries = <String>[];
    await pumpEditor(
      tester,
      entries: List.generate(1000, (index) => 'entry $index'),
      onChanged: (value) => entries = value,
    );

    expect(find.byType(TextField).evaluate().length, lessThan(20));
    await tester.enterText(
      find.byKey(const Key('prompt-entry-field-0')),
      'updated',
    );
    await tester.pump();

    expect(entries, hasLength(1000));
    expect(entries.first, 'updated');
    expect(entries.last, 'entry 999');
  });
}
