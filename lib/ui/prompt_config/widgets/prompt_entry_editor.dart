import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_assistance.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_transform.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_entry_divider.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_search_replace_bar.dart';

part 'prompt_entry_document.dart';
part 'prompt_entry_divider_overlay.dart';

class PromptEntryEditor extends StatefulWidget {
  const PromptEntryEditor({
    super.key,
    required this.initialEntries,
    required this.onChanged,
    this.promptAssistance,
    this.autocompleteEnabled = true,
  });

  final List<String> initialEntries;
  final ValueChanged<List<String>> onChanged;
  final PromptEditingAssistance? promptAssistance;
  final bool autocompleteEnabled;

  @override
  State<PromptEntryEditor> createState() => _PromptEntryEditorState();
}

class _PromptEntryEditorState extends State<PromptEntryEditor> {
  static const _maxHistoryLength = 100;
  static const _contentPadding = EdgeInsets.symmetric(
    horizontal: 12,
    vertical: 8,
  );
  static const _strutStyle = StrutStyle(
    height: 1.2,
    forceStrutHeight: false,
  );

  late final _PromptDocumentController _controller;
  late final _PromptDocumentFormatter _formatter;
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  late final GlobalKey _editorLayoutKey;
  late final GlobalKey<PromptAssistedTextFieldState> _assistedFieldKey;
  late final List<_EditorSnapshot> _history;
  int _historyIndex = 0;
  bool _restoringHistory = false;
  bool _searchVisible = false;

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
    _editorLayoutKey = GlobalKey();
    _assistedFieldKey = GlobalKey<PromptAssistedTextFieldState>();
    _history = [_snapshot()];
  }

  bool get _hasComposingText {
    final composing = _controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final isKeyDown = event is KeyDownEvent;
    final isKeyRepeat = event is KeyRepeatEvent;
    if (!isKeyDown && !isKeyRepeat) return KeyEventResult.ignored;

    final hardware = HardwareKeyboard.instance;
    final modifierPressed = hardware.isMetaPressed || hardware.isControlPressed;
    if (isKeyDown &&
        modifierPressed &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (hardware.isShiftPressed) {
        _redo();
      } else {
        _undo();
      }
      return KeyEventResult.handled;
    }
    if (isKeyDown &&
        hardware.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyY) {
      _redo();
      return KeyEventResult.handled;
    }
    if (isKeyDown &&
        modifierPressed &&
        !hardware.isShiftPressed &&
        !hardware.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      setState(() {
        _searchVisible = true;
      });
      return KeyEventResult.handled;
    }

    final controlShortcutResult = _handleControlPromptShortcut(
      event,
      hardware,
    );
    if (controlShortcutResult != null) return controlShortcutResult;

    if (!_hasComposingText &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown)) {
      _scheduleVerticalBoundaryCorrection(
        before: _safeSelection(_controller.value),
        moveDown: event.logicalKey == LogicalKeyboardKey.arrowDown,
        extendSelection: hardware.isShiftPressed,
      );
      return KeyEventResult.ignored;
    }

    // Repeated key events are only meaningful here for vertical navigation.
    // Editing shortcuts below must continue to run once per physical key-down.
    if (isKeyRepeat) return KeyEventResult.ignored;

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

  KeyEventResult? _handleControlPromptShortcut(
    KeyEvent event,
    HardwareKeyboard hardware,
  ) {
    if (!hardware.isControlPressed ||
        hardware.isMetaPressed ||
        hardware.isAltPressed ||
        hardware.isShiftPressed) {
      return null;
    }

    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => PromptWeightDirection.increase,
      LogicalKeyboardKey.arrowDown => PromptWeightDirection.decrease,
      _ => null,
    };
    final moveDirection = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => PromptMoveDirection.backward,
      LogicalKeyboardKey.arrowRight => PromptMoveDirection.forward,
      _ => null,
    };
    if (direction == null && moveDirection == null) return null;

    // Keep composition confirmation and candidate text entry ahead of all
    // editor transforms.  Returning ignored lets the platform/IME consume
    // the key normally.
    if (_hasComposingText) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final value = _controller.value;
    final selection = _safeSelection(value);
    final entryRange = _controller.entryRangeForOffset(selection.extentOffset);
    if (entryRange == null) return KeyEventResult.handled;

    final result = direction != null
        ? PromptEditingTransform.adjustWeight(
            value,
            direction: direction,
            scope: PromptEditingScope.cascadedEntry,
            editableRange: TextRange(
              start: entryRange.start,
              end: entryRange.end,
            ),
          )
        : PromptEditingTransform.move(
            value,
            direction: moveDirection!,
            scope: PromptEditingScope.cascadedEntry,
            editableRange: TextRange(
              start: entryRange.start,
              end: entryRange.end,
            ),
          );
    if (result.changed) {
      _rememberSelection(selection);
      _assistedFieldKey.currentState?.setEditingValue(result.value);
      _emitAndRecord();
    }
    // Consume a Control-arrow at a boundary as well; otherwise native word
    // navigation would move the caret despite the transform being a no-op.
    return KeyEventResult.handled;
  }

  void _scheduleVerticalBoundaryCorrection({
    required TextSelection before,
    required bool moveDown,
    required bool extendSelection,
  }) {
    if ((!before.isCollapsed && !extendSelection) ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final after = _safeSelection(_controller.value);
      final boundary = _controller.crossedEntryBoundary(
        before.extentOffset,
        after.extentOffset,
        moveDown: moveDown,
      );
      if (boundary == null) return;
      final targetRange = _controller.entryRangeAcrossBoundary(
        boundary,
        moveDown: moveDown,
      );
      if (targetRange.start == targetRange.end) {
        _setVerticalSelection(
          before: before,
          desiredOffset: targetRange.start,
          extendSelection: extendSelection,
        );
        return;
      }
      final renderEditable = _findRenderEditable();
      if (renderEditable == null) return;
      final beforeCaret = renderEditable.getLocalRectForCaret(
        TextPosition(offset: before.extentOffset),
      );
      final targetLineCaret = renderEditable.getLocalRectForCaret(
        TextPosition(
          offset: moveDown ? targetRange.start : targetRange.end,
          affinity: moveDown ? TextAffinity.downstream : TextAffinity.upstream,
        ),
      );
      final desiredOffset = renderEditable
          .getPositionForPoint(
            renderEditable.localToGlobal(
              Offset(beforeCaret.left, targetLineCaret.center.dy),
            ),
          )
          .offset;
      if (after.extentOffset == desiredOffset) return;
      _setVerticalSelection(
        before: before,
        desiredOffset: desiredOffset.clamp(
          targetRange.start,
          targetRange.end,
        ),
        extendSelection: extendSelection,
      );
    });
  }

  void _setVerticalSelection({
    required TextSelection before,
    required int desiredOffset,
    required bool extendSelection,
  }) {
    _controller.selection = extendSelection
        ? TextSelection(
            baseOffset: before.baseOffset,
            extentOffset: desiredOffset,
          )
        : TextSelection.collapsed(offset: desiredOffset);
  }

  RenderEditable? _findRenderEditable() {
    RenderEditable? result;
    void visit(RenderObject child) {
      if (result != null) return;
      if (child is RenderEditable) {
        result = child;
        return;
      }
      child.visitChildren(visit);
    }

    context.findRenderObject()?.visitChildren(visit);
    return result;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PromptSearchReplaceBar(
          controller: _controller,
          focusNode: _focusNode,
          visible: _searchVisible,
          onClose: () => setState(() => _searchVisible = false),
          onChanged: (_) => _handleTextChanged(_controller.text),
        ),
        Expanded(
          child: PromptAssistedTextField(
            key: _assistedFieldKey,
            initialValue: _controller.text,
            onChanged: _handleTextChanged,
            assistance: widget.promptAssistance,
            completionEnabled:
                widget.autocompleteEnabled && widget.promptAssistance != null,
            controller: _controller,
            focusNode: _focusNode,
            onExternalEdit: _applyCompletionEdit,
            refreshController: _controller.refresh,
            fieldBuilder: (
              context,
              controller,
              focusNode,
              onChanged,
              loading,
            ) {
              return Stack(
                key: _editorLayoutKey,
                fit: StackFit.expand,
                children: [
                  TextField(
                    key: const Key('prompt-entry-editor'),
                    controller: controller,
                    focusNode: focusNode,
                    scrollController: _scrollController,
                    inputFormatters: [_formatter],
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    autofocus: true,
                    style: style,
                    strutStyle: _strutStyle,
                    selectionHeightStyle: ui.BoxHeightStyle.strut,
                    textAlignVertical: TextAlignVertical.top,
                    onChanged: onChanged,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor:
                          theme.colorScheme.surfaceContainerHighest.withAlpha(70),
                      border: const OutlineInputBorder(),
                      contentPadding: _contentPadding,
                      suffixIcon: loading
                          ? const Padding(
                              key: Key('prompt-assistance-loading'),
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                    ),
                  ),
                  IgnorePointer(
                    child: CustomPaint(
                      key: const Key('prompt-entry-divider-overlay'),
                      painter: _PromptEntryDividerOverlayPainter(
                        controller: _controller,
                        scrollController: _scrollController,
                        color: promptEntryDividerColor(context),
                        editorLayoutKey: _editorLayoutKey,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  void _applyCompletionEdit(
    TextEditingValue oldValue,
    TextEditingValue newValue,
    TextRange replacementRange,
  ) {
    _controller.remapBoundaries(
      oldValue,
      newValue,
      insertedNewlinesAreBoundaries: false,
      replacement: _TextReplacement(
        start: replacementRange.start,
        end: replacementRange.end,
        insertedText: newValue.text.substring(
          replacementRange.start,
          replacementRange.start +
              (newValue.text.length -
                  oldValue.text.length +
                  replacementRange.end -
                  replacementRange.start),
        ),
      ),
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
