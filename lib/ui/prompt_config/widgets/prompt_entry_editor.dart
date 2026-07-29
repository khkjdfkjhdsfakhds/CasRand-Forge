import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';

class PromptEntryEditor extends StatefulWidget {
  const PromptEntryEditor({
    super.key,
    required this.initialEntries,
    required this.onChanged,
    required this.helpText,
    required this.insertLineBreakLabel,
    required this.commentLabel,
  });

  final List<String> initialEntries;
  final ValueChanged<List<String>> onChanged;
  final String helpText;
  final String insertLineBreakLabel;
  final String commentLabel;

  @override
  State<PromptEntryEditor> createState() => _PromptEntryEditorState();
}

class _PromptEntryEditorState extends State<PromptEntryEditor> {
  static const _maxHistoryLength = 100;

  late final List<_PromptEntryField> _fields;
  late final List<_EditorSnapshot> _history;
  int _historyIndex = 0;
  int _activeIndex = 0;
  bool _restoringHistory = false;

  @override
  void initState() {
    super.initState();
    final entries =
        widget.initialEntries.isEmpty ? const [''] : widget.initialEntries;
    _fields = entries.map(_createField).toList(growable: true);
    _history = [
      _EditorSnapshot(
        entries: _entries,
        activeIndex: 0,
        selection: _fields.first.controller.selection,
      ),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fields.first.focusNode.requestFocus();
    });
  }

  _PromptEntryField _createField(String text) {
    late final _PromptEntryField field;
    final controller = _PromptEntryTextController(text: text);
    final focusNode = FocusNode();
    field = _PromptEntryField(controller: controller, focusNode: focusNode);
    focusNode.onKeyEvent = (node, event) => _handleKeyEvent(field, event);
    focusNode.addListener(() {
      if (!mounted || !focusNode.hasFocus) return;
      final index = _fields.indexOf(field);
      if (index >= 0) _activeIndex = index;
    });
    field.formatter = _PromptEntryBoundaryFormatter(
      onEditStarted: (value) => _rememberSelection(field, value.selection),
      onBoundaryInserted: (replacement) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_fields.contains(field)) return;
          _splitReplacement(field, replacement);
        });
      },
    );
    return field;
  }

  void _rememberSelection(
    _PromptEntryField field,
    TextSelection selection,
  ) {
    if (_restoringHistory || _history.isEmpty) return;
    final index = _fields.indexOf(field);
    if (index < 0) return;
    final current = _history[_historyIndex];
    _history[_historyIndex] = _EditorSnapshot(
      entries: current.entries,
      activeIndex: index,
      selection: selection,
    );
  }

  List<String> get _entries =>
      _fields.map((field) => field.controller.text).toList(growable: false);

  bool get _hasComposingText {
    final composing = _fields[_activeIndex].controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  KeyEventResult _handleKeyEvent(
    _PromptEntryField field,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final index = _fields.indexOf(field);
    if (index < 0) return KeyEventResult.ignored;
    _activeIndex = index;

    final hardware = HardwareKeyboard.instance;
    final modifierPressed = hardware.isMetaPressed || hardware.isControlPressed;
    if (modifierPressed && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (hardware.isShiftPressed) {
        _redo();
      } else {
        _undo();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyY) {
      _redo();
      return KeyEventResult.handled;
    }

    if (_hasComposingText) {
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        field.formatter.expectImeConfirmation();
      }
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (hardware.isShiftPressed) {
        _insertLineBreak(index);
      } else {
        _splitAtSelection(index);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final selection = field.controller.selection;
      if (index > 0 &&
          selection.isValid &&
          selection.isCollapsed &&
          selection.baseOffset == 0) {
        _mergeWithPrevious(index);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  void _splitAtSelection(int index) {
    final controller = _fields[index].controller;
    final selection = _safeSelection(controller);
    _splitReplacement(
      _fields[index],
      _TextReplacement(
        start: selection.start,
        end: selection.end,
        insertedText: '\n',
      ),
    );
  }

  void _splitReplacement(
    _PromptEntryField field,
    _TextReplacement replacement,
  ) {
    final index = _fields.indexOf(field);
    if (index < 0) return;
    final source = field.controller.text;
    final start = replacement.start.clamp(0, source.length);
    final end = replacement.end.clamp(start, source.length);
    _rememberSelection(
      field,
      TextSelection(baseOffset: start, extentOffset: end),
    );
    final inserted = replacement.insertedText.replaceAll('\r\n', '\n');
    final pieces = inserted.replaceAll('\r', '\n').split('\n');
    if (pieces.length < 2) return;

    final replacementEntries = <String>[
      '${source.substring(0, start)}${pieces.first}',
      ...pieces.skip(1).take(pieces.length - 2),
      '${pieces.last}${source.substring(end)}',
    ];
    final newFields = replacementEntries.map(_createField).toList();
    final removed = _fields.removeAt(index);
    _fields.insertAll(index, newFields);
    _activeIndex = index + newFields.length - 1;
    newFields.last.controller.selection = TextSelection.collapsed(
      offset: pieces.last.length,
    );
    _disposeAfterFrame([removed]);
    _emitAndRecord();
    _focusAfterFrame(_activeIndex);
  }

  void _insertLineBreak([int? requestedIndex]) {
    if (_fields.isEmpty) return;
    final index = (requestedIndex ?? _activeIndex).clamp(0, _fields.length - 1);
    final controller = _fields[index].controller;
    final selection = _safeSelection(controller);
    _rememberSelection(_fields[index], selection);
    final nextText = controller.text.replaceRange(
      selection.start,
      selection.end,
      '\n',
    );
    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
    _activeIndex = index;
    _emitAndRecord();
    _focusAfterFrame(index);
  }

  void _mergeWithPrevious(int index) {
    final previous = _fields[index - 1];
    final current = _fields[index];
    _rememberSelection(current, _safeSelection(current.controller));
    final caret = previous.controller.text.length;
    previous.controller.value = TextEditingValue(
      text: '${previous.controller.text}${current.controller.text}',
      selection: TextSelection.collapsed(offset: caret),
    );
    _fields.removeAt(index);
    _activeIndex = index - 1;
    _disposeAfterFrame([current]);
    _emitAndRecord();
    _focusAfterFrame(_activeIndex);
  }

  TextSelection _safeSelection(TextEditingController controller) {
    final selection = controller.selection;
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: controller.text.length);
    }
    return TextSelection(
      baseOffset: selection.baseOffset.clamp(0, controller.text.length),
      extentOffset: selection.extentOffset.clamp(0, controller.text.length),
    );
  }

  void _handleTextChanged(int index) {
    if (_restoringHistory) return;
    _activeIndex = index;
    _emitAndRecord();
  }

  void _emitAndRecord() {
    setState(() {});
    final entries = _entries;
    widget.onChanged(List.unmodifiable(entries));
    if (_restoringHistory) return;

    final snapshot = _EditorSnapshot(
      entries: entries,
      activeIndex: _activeIndex,
      selection: _safeSelection(_fields[_activeIndex].controller),
    );
    if (listEquals(_history[_historyIndex].entries, snapshot.entries)) return;
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _history.add(snapshot);
    _historyIndex = _history.length - 1;
    if (_history.length > _maxHistoryLength) {
      _history.removeAt(0);
      _historyIndex--;
    }
  }

  void _undo() {
    if (_historyIndex == 0) return;
    _historyIndex--;
    _restoreSnapshot(_history[_historyIndex]);
  }

  void _redo() {
    if (_historyIndex >= _history.length - 1) return;
    _historyIndex++;
    _restoreSnapshot(_history[_historyIndex]);
  }

  void _restoreSnapshot(_EditorSnapshot snapshot) {
    _restoringHistory = true;
    final removed = <_PromptEntryField>[];
    while (_fields.length > snapshot.entries.length) {
      removed.add(_fields.removeLast());
    }
    while (_fields.length < snapshot.entries.length) {
      _fields.add(_createField(''));
    }
    for (final (index, entry) in snapshot.entries.indexed) {
      final controller = _fields[index].controller;
      controller.value = TextEditingValue(
        text: entry,
        selection: index == snapshot.activeIndex
            ? TextSelection(
                baseOffset:
                    snapshot.selection.baseOffset.clamp(0, entry.length),
                extentOffset:
                    snapshot.selection.extentOffset.clamp(0, entry.length),
              )
            : TextSelection.collapsed(offset: entry.length),
      );
    }
    _activeIndex = snapshot.activeIndex.clamp(0, _fields.length - 1);
    setState(() {});
    widget.onChanged(List.unmodifiable(_entries));
    _restoringHistory = false;
    _disposeAfterFrame(removed);
    _focusAfterFrame(_activeIndex);
  }

  void _focusAfterFrame(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || index >= _fields.length) return;
      _fields[index].focusNode.requestFocus();
    });
  }

  void _disposeAfterFrame(List<_PromptEntryField> fields) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final field in fields) {
        field.dispose();
      }
    });
  }

  List<int?> get _entryNumbers {
    var number = 0;
    return _fields.map((field) {
      if (PromptConfig.entryHasPrompt(field.controller.text)) {
        number++;
        return number;
      }
      return null;
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final entryNumbers = _entryNumbers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.helpText,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: _fields.length,
            itemBuilder: (context, index) {
              final field = _fields[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PromptEntryDivider(
                    key: Key('prompt-entry-divider-$index'),
                    number: entryNumbers[index],
                    commentLabel: widget.commentLabel,
                  ),
                  TextField(
                    key: Key('prompt-entry-field-$index'),
                    controller: field.controller,
                    focusNode: field.focusNode,
                    inputFormatters: [field.formatter],
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    minLines: 1,
                    maxLines: null,
                    onTap: () => _activeIndex = index,
                    onChanged: (_) => _handleTextChanged(index),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withAlpha(70),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              );
            },
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('insert-prompt-line-break'),
            onPressed: _insertLineBreak,
            icon: const Icon(Icons.keyboard_return, size: 18),
            label: Text(widget.insertLineBreakLabel),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }
}

class _PromptEntryDivider extends StatelessWidget {
  const _PromptEntryDivider({
    super.key,
    required this.number,
    required this.commentLabel,
  });

  final int? number;
  final String commentLabel;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        );
    final label = number == null
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.comment_outlined, size: 13),
              const SizedBox(width: 4),
              Text(commentLabel, style: labelStyle),
            ],
          )
        : Text('$number', style: labelStyle);

    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Divider(color: color, height: 1)),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: color.withAlpha(45),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: color),
              ),
              child: IconTheme(
                data: IconThemeData(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                child: label,
              ),
            ),
            Expanded(child: Divider(color: color, height: 1)),
          ],
        ),
      ),
    );
  }
}

class _PromptEntryTextController extends TextEditingController {
  _PromptEntryTextController({required String text}) : super(text: text);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final commentStyle = baseStyle.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    final spans = <InlineSpan>[];
    var offset = 0;
    final lines = text.split('\n');
    for (final (index, line) in lines.indexed) {
      final segment = index == lines.length - 1 ? line : '$line\n';
      final lineStyle =
          PromptConfig.isCommentLine(line) ? commentStyle : baseStyle;
      spans.add(
        _styledSpan(
          text: segment,
          start: offset,
          style: lineStyle,
          withComposing: withComposing,
        ),
      );
      offset += segment.length;
    }
    return TextSpan(style: baseStyle, children: spans);
  }

  TextSpan _styledSpan({
    required String text,
    required int start,
    required TextStyle style,
    required bool withComposing,
  }) {
    final composing = value.composing;
    final end = start + text.length;
    if (!withComposing ||
        !composing.isValid ||
        composing.isCollapsed ||
        composing.end <= start ||
        composing.start >= end) {
      return TextSpan(text: text, style: style);
    }

    final localStart = (composing.start - start).clamp(0, text.length);
    final localEnd = (composing.end - start).clamp(localStart, text.length);
    return TextSpan(
      style: style,
      children: [
        if (localStart > 0) TextSpan(text: text.substring(0, localStart)),
        TextSpan(
          text: text.substring(localStart, localEnd),
          style: style.copyWith(decoration: TextDecoration.underline),
        ),
        if (localEnd < text.length) TextSpan(text: text.substring(localEnd)),
      ],
    );
  }
}

class _PromptEntryBoundaryFormatter extends TextInputFormatter {
  _PromptEntryBoundaryFormatter({
    required this.onEditStarted,
    required this.onBoundaryInserted,
  });

  final ValueChanged<TextEditingValue> onEditStarted;
  final ValueChanged<_TextReplacement> onBoundaryInserted;
  bool _expectingImeConfirmation = false;

  void expectImeConfirmation() {
    _expectingImeConfirmation = true;
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    onEditStarted(oldValue);
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final replacement = _replacementBetween(oldValue.text, newValue.text);
    if (oldValue.composing.isValid &&
        !oldValue.composing.isCollapsed &&
        _expectingImeConfirmation) {
      _expectingImeConfirmation = false;
      if (oldValue.text == newValue.text) {
        final composingText = oldValue.composing.textInside(oldValue.text);
        if (composingText.contains('\n') || composingText.contains('\r')) {
          final committedText = _withoutBoundaries(composingText);
          final text = oldValue.text.replaceRange(
            oldValue.composing.start,
            oldValue.composing.end,
            committedText,
          );
          return TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(
              offset: oldValue.composing.start + committedText.length,
            ),
          );
        }
      }
      if (replacement.insertedText.contains('\n') ||
          replacement.insertedText.contains('\r')) {
        final committedText = _withoutBoundaries(replacement.insertedText);
        final text = oldValue.text.replaceRange(
          replacement.start,
          replacement.end,
          committedText,
        );
        return TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(
            offset: replacement.start + committedText.length,
          ),
        );
      }
    }
    _expectingImeConfirmation = false;
    if (!replacement.insertedText.contains('\n') &&
        !replacement.insertedText.contains('\r')) {
      return newValue;
    }
    if (HardwareKeyboard.instance.isShiftPressed &&
        replacement.insertedText == '\n') {
      return newValue;
    }
    onBoundaryInserted(replacement);
    return oldValue;
  }

  String _withoutBoundaries(String value) =>
      value.replaceAll('\r\n', '').replaceAll(RegExp(r'[\r\n]'), '');

  _TextReplacement _replacementBetween(String oldText, String newText) {
    var prefix = 0;
    final sharedLength =
        oldText.length < newText.length ? oldText.length : newText.length;
    while (prefix < sharedLength &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }

    var oldSuffix = oldText.length;
    var newSuffix = newText.length;
    while (oldSuffix > prefix &&
        newSuffix > prefix &&
        oldText.codeUnitAt(oldSuffix - 1) ==
            newText.codeUnitAt(newSuffix - 1)) {
      oldSuffix--;
      newSuffix--;
    }

    return _TextReplacement(
      start: prefix,
      end: oldSuffix,
      insertedText: newText.substring(prefix, newSuffix),
    );
  }
}

class _TextReplacement {
  const _TextReplacement({
    required this.start,
    required this.end,
    required this.insertedText,
  });

  final int start;
  final int end;
  final String insertedText;
}

class _PromptEntryField {
  _PromptEntryField({
    required this.controller,
    required this.focusNode,
  });

  final _PromptEntryTextController controller;
  final FocusNode focusNode;
  late final _PromptEntryBoundaryFormatter formatter;

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.entries,
    required this.activeIndex,
    required this.selection,
  });

  final List<String> entries;
  final int activeIndex;
  final TextSelection selection;
}
