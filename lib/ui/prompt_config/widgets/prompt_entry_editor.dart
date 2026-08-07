import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_divider.dart';

part 'prompt_entry_document.dart';
part 'prompt_entry_divider_overlay.dart';

class PromptEntryEditor extends StatefulWidget {
  const PromptEntryEditor({
    super.key,
    required this.initialEntries,
    required this.onChanged,
  });

  final List<String> initialEntries;
  final ValueChanged<List<String>> onChanged;

  @override
  State<PromptEntryEditor> createState() => _PromptEntryEditorState();
}

class _PromptEntryEditorState extends State<PromptEntryEditor> {
  static const _maxHistoryLength = 100;
  static const _contentPadding = EdgeInsets.symmetric(vertical: 8);

  late final _PromptDocumentController _controller;
  late final _PromptDocumentFormatter _formatter;
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  late final List<_EditorSnapshot> _history;
  int _historyIndex = 0;
  bool _restoringHistory = false;

  @override
  void initState() {
    super.initState();
    _controller = _PromptDocumentController.fromEntries(widget.initialEntries);
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    _formatter = _PromptDocumentFormatter(
      controller: _controller,
      onEditStarted: _rememberSelection,
    );
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
    _scrollController = ScrollController();
    _history = [_snapshot()];
  }

  bool get _hasComposingText {
    final composing = _controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

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
      if (_isEnter(event.logicalKey)) {
        _formatter.expectImeConfirmation();
      }
      return KeyEventResult.ignored;
    }

    if (_isEnter(event.logicalKey)) {
      _replaceSelection(
        '\n',
        insertedNewlinesAreBoundaries: !hardware.isShiftPressed,
      );
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        _deleteSelectionOrBoundary(backward: true)) {
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete &&
        _deleteSelectionOrBoundary(backward: false)) {
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _isEnter(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter;

  void _replaceSelection(
    String replacement, {
    required bool insertedNewlinesAreBoundaries,
  }) {
    final oldValue = _controller.value;
    final selection = _safeSelection(oldValue);
    _rememberSelection(selection);
    final newText = oldValue.text.replaceRange(
      selection.start,
      selection.end,
      replacement,
    );
    final newValue = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: selection.start + replacement.length,
      ),
    );
    _controller.remapBoundaries(
      oldValue,
      newValue,
      insertedNewlinesAreBoundaries: insertedNewlinesAreBoundaries,
      replacement: _TextReplacement(
        start: selection.start,
        end: selection.end,
        insertedText: replacement,
      ),
    );
    _controller.value = newValue;
    _emitAndRecord();
  }

  bool _deleteSelectionOrBoundary({required bool backward}) {
    final value = _controller.value;
    final selection = _safeSelection(value);
    if (!selection.isCollapsed) {
      _replaceSelection('', insertedNewlinesAreBoundaries: false);
      return true;
    }

    final boundaryOffset = backward ? selection.start - 1 : selection.start;
    if (!_controller.boundaryOffsets.contains(boundaryOffset)) return false;
    final deleteSelection = TextSelection(
      baseOffset: boundaryOffset,
      extentOffset: boundaryOffset + 1,
    );
    _controller.selection = deleteSelection;
    _replaceSelection('', insertedNewlinesAreBoundaries: false);
    return true;
  }

  TextSelection _safeSelection(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: value.text.length);
    }
    return TextSelection(
      baseOffset: selection.baseOffset.clamp(0, value.text.length),
      extentOffset: selection.extentOffset.clamp(0, value.text.length),
    );
  }

  void _handleTextChanged(String _) {
    if (_restoringHistory) return;
    _emitAndRecord();
  }

  void _rememberSelection(TextSelection selection) {
    if (_restoringHistory || _history.isEmpty) return;
    final current = _history[_historyIndex];
    _history[_historyIndex] = current.copyWith(selection: selection);
  }

  _EditorSnapshot _snapshot() => _EditorSnapshot(
        text: _controller.text,
        boundaryOffsets: _controller.sortedBoundaryOffsets,
        selection: _safeSelection(_controller.value),
      );

  void _emitAndRecord() {
    setState(() {});
    widget.onChanged(List.unmodifiable(_controller.entries));
    if (_restoringHistory) return;

    final snapshot = _snapshot();
    final current = _history[_historyIndex];
    if (current.text == snapshot.text &&
        listEquals(current.boundaryOffsets, snapshot.boundaryOffsets)) {
      return;
    }
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
    _controller.restore(snapshot);
    setState(() {});
    widget.onChanged(List.unmodifiable(_controller.entries));
    _restoringHistory = false;
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
    final commentStyle = style.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        TextField(
          key: const Key('prompt-entry-editor'),
          controller: _controller,
          focusNode: _focusNode,
          scrollController: _scrollController,
          inputFormatters: [_formatter],
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          expands: true,
          minLines: null,
          maxLines: null,
          autofocus: true,
          style: style,
          textAlignVertical: TextAlignVertical.top,
          onChanged: _handleTextChanged,
          decoration: const InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: _contentPadding,
          ),
        ),
        IgnorePointer(
          child: CustomPaint(
            key: const Key('prompt-entry-divider-overlay'),
            painter: _PromptEntryDividerOverlayPainter(
              controller: _controller,
              scrollController: _scrollController,
              style: style,
              commentStyle: commentStyle,
              color: promptEntryDividerColor(context),
              textDirection: textDirection,
              textScaler: textScaler,
              contentPadding: _contentPadding,
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
