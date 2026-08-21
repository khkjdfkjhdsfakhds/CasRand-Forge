part of 'prompt_entry_editor.dart';

class _PromptDocumentController extends TextEditingController
    with SearchHighlightable {
  _PromptDocumentController.fromEntries(List<String> initialEntries)
      : _boundaryOffsets = _boundariesForEntries(initialEntries),
        super(text: _textForEntries(initialEntries));

  final Set<int> _boundaryOffsets;
  List<int>? _sortedBoundaryCache;
  int _layoutRevision = 0;
  bool _suppressRemap = false;

  Set<int> get boundaryOffsets => Set.unmodifiable(_boundaryOffsets);

  int get layoutRevision => _layoutRevision;

  void refresh() => notifyListeners();

  @override
  set value(TextEditingValue newValue) {
    if (!_suppressRemap && newValue.text != text) {
      remapBoundaries(
        value,
        newValue,
        insertedNewlinesAreBoundaries: false,
      );
    }
    _suppressRemap = false;
    super.value = newValue;
  }

  List<int> get sortedBoundaryOffsets {
    return List.unmodifiable(_sortedBoundaries);
  }

  List<int> get _sortedBoundaries =>
      _sortedBoundaryCache ??= (_boundaryOffsets.toList()..sort());

  int? crossedEntryBoundary(
    int from,
    int to, {
    required bool moveDown,
  }) {
    if (from == to) return null;
    final start = from < to ? from : to;
    final end = from < to ? to : from;
    final boundaries = _sortedBoundaries;
    final firstIndex = _lowerBound(boundaries, start);
    if (firstIndex == boundaries.length || boundaries[firstIndex] >= end) {
      return null;
    }
    if (moveDown) return boundaries[firstIndex];
    final endIndex = _lowerBound(boundaries, end);
    return boundaries[endIndex - 1];
  }

  ({int start, int end}) entryRangeAcrossBoundary(
    int boundary, {
    required bool moveDown,
  }) {
    final boundaries = _sortedBoundaries;
    final boundaryIndex = _lowerBound(boundaries, boundary);
    assert(
      boundaryIndex < boundaries.length &&
          boundaries[boundaryIndex] == boundary,
    );
    if (moveDown) {
      return (
        start: boundary + 1,
        end: boundaryIndex + 1 < boundaries.length
            ? boundaries[boundaryIndex + 1]
            : text.length,
      );
    }
    return (
      start: boundaryIndex == 0 ? 0 : boundaries[boundaryIndex - 1] + 1,
      end: boundary,
    );
  }

  List<String> get entries {
    final result = <String>[];
    var start = 0;
    for (final boundary in sortedBoundaryOffsets) {
      if (boundary < start ||
          boundary >= text.length ||
          text.codeUnitAt(boundary) != 0x0A) {
        continue;
      }
      result.add(text.substring(start, boundary));
      start = boundary + 1;
    }
    result.add(text.substring(start));
    return result;
  }

  /// Returns the editable span for the candidate containing [offset].
  ///
  /// A caret exactly before a boundary newline belongs to the preceding
  /// candidate, matching the ordinary text-editing interpretation of that
  /// position.  The boundary newline itself is never included in the span.
  ({int start, int end})? entryRangeForOffset(int offset) {
    if (offset < 0 || offset > text.length) return null;
    final boundaries = _sortedBoundaries;
    final index = _lowerBound(boundaries, offset);
    if (index < boundaries.length &&
        boundaries[index] == offset &&
        offset > 0) {
      final start = index == 0 ? 0 : boundaries[index - 1] + 1;
      return (start: start, end: offset);
    }
    final start = index == 0 ? 0 : boundaries[index - 1] + 1;
    final end = index < boundaries.length ? boundaries[index] : text.length;
    return (start: start, end: end);
  }

  void remapBoundaries(
    TextEditingValue oldValue,
    TextEditingValue newValue, {
    required bool insertedNewlinesAreBoundaries,
    _TextReplacement? replacement,
  }) {
    _suppressRemap = true;
    final effectiveReplacement =
        replacement ?? _replacementBetween(oldValue.text, newValue.text);
    final removedLength = effectiveReplacement.end - effectiveReplacement.start;
    final delta = effectiveReplacement.insertedText.length - removedLength;
    final updated = <int>{};

    for (final boundary in _boundaryOffsets) {
      if (boundary < effectiveReplacement.start) {
        updated.add(boundary);
      } else if (boundary >= effectiveReplacement.end) {
        updated.add(boundary + delta);
      }
    }

    if (insertedNewlinesAreBoundaries) {
      for (var index = 0;
          index < effectiveReplacement.insertedText.length;
          index++) {
        if (effectiveReplacement.insertedText.codeUnitAt(index) == 0x0A) {
          updated.add(effectiveReplacement.start + index);
        }
      }
    }

    _boundaryOffsets
      ..clear()
      ..addAll(updated.where(
        (offset) =>
            offset >= 0 &&
            offset < newValue.text.length &&
            newValue.text.codeUnitAt(offset) == 0x0A,
      ));
    _sortedBoundaryCache = null;
    _layoutRevision++;
  }

  void restore(_EditorSnapshot snapshot) {
    _boundaryOffsets
      ..clear()
      ..addAll(snapshot.boundaryOffsets);
    _sortedBoundaryCache = null;
    _layoutRevision++;
    _suppressRemap = true;
    value = TextEditingValue(
      text: snapshot.text,
      selection: snapshot.selection,
    );
  }

  TextSpan documentSpan({
    required TextStyle style,
    required TextStyle commentStyle,
    required bool withComposing,
  }) {
    final spans = <InlineSpan>[];
    var lineStart = 0;
    for (var offset = 0; offset <= text.length; offset++) {
      final atEnd = offset == text.length;
      final atLineBreak = !atEnd && text.codeUnitAt(offset) == 0x0A;
      if (!atEnd && !atLineBreak) continue;

      final line = text.substring(lineStart, offset);
      final lineStyle = PromptConfig.isCommentLine(line) ? commentStyle : style;
      if (line.isNotEmpty) {
        final followsBoundary =
            lineStart > 0 && _boundaryOffsets.contains(lineStart - 1);
        if (followsBoundary) {
          spans
            ..add(
              _styledSpan(
                text: line.substring(0, 1),
                start: lineStart,
                style: _entryBoundaryStyle(lineStyle),
                withComposing: withComposing,
              ),
            )
            ..add(
              _styledSpan(
                text: line.substring(1),
                start: lineStart + 1,
                style: lineStyle,
                withComposing: withComposing,
              ),
            );
        } else {
          spans.add(
            _styledSpan(
              text: line,
              start: lineStart,
              style: lineStyle,
              withComposing: withComposing,
            ),
          );
        }
      }
      if (atLineBreak) {
        spans.add(
          _styledSpan(
            text: '\n',
            start: offset,
            style: lineStyle,
            withComposing: withComposing,
          ),
        );
      }
      lineStart = offset + 1;
    }
    return TextSpan(children: spans);
  }

  TextStyle _entryBoundaryStyle(TextStyle style) {
    final fontSize = style.fontSize ?? 14;
    final baseHeight = style.height ?? 1.2;
    return style.copyWith(
      height:
          baseHeight + PromptEntryDivider.editorBoundaryExtraLeading / fontSize,
      leadingDistribution: TextLeadingDistribution.even,
    );
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

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final base = documentSpan(
      style: baseStyle,
      commentStyle: baseStyle.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontStyle: FontStyle.italic,
      ),
      withComposing: withComposing,
    );
    return applySearchHighlights(base, context);
  }

  static String _textForEntries(List<String> initialEntries) {
    final entries = initialEntries.isEmpty ? const [''] : initialEntries;
    return entries.join('\n');
  }

  static Set<int> _boundariesForEntries(List<String> initialEntries) {
    final entries = initialEntries.isEmpty ? const [''] : initialEntries;
    final boundaries = <int>{};
    var offset = 0;
    for (var index = 0; index < entries.length - 1; index++) {
      offset += entries[index].length;
      boundaries.add(offset);
      offset++;
    }
    return boundaries;
  }

  static int _lowerBound(List<int> values, int target) {
    var low = 0;
    var high = values.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (values[middle] < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

class _PromptDocumentFormatter extends TextInputFormatter {
  _PromptDocumentFormatter({
    required this.controller,
    required this.onEditStarted,
  });

  final _PromptDocumentController controller;
  final ValueChanged<TextSelection> onEditStarted;
  bool _expectingImeConfirmation = false;

  void expectImeConfirmation() {
    _expectingImeConfirmation = true;
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    onEditStarted(oldValue.selection);
    final normalizedValue = _normalizeLineEndings(newValue);
    if (normalizedValue.composing.isValid &&
        !normalizedValue.composing.isCollapsed) {
      controller.remapBoundaries(
        oldValue,
        normalizedValue,
        insertedNewlinesAreBoundaries: false,
      );
      return normalizedValue;
    }

    final replacement = _replacementBetween(
      oldValue.text,
      normalizedValue.text,
    );
    if (oldValue.composing.isValid &&
        !oldValue.composing.isCollapsed &&
        _expectingImeConfirmation) {
      _expectingImeConfirmation = false;
      final committedValue = _committedImeValue(
        oldValue,
        normalizedValue,
        replacement,
      );
      controller.remapBoundaries(
        oldValue,
        committedValue,
        insertedNewlinesAreBoundaries: false,
      );
      return committedValue;
    }

    _expectingImeConfirmation = false;
    final internalLineBreak = HardwareKeyboard.instance.isShiftPressed &&
        replacement.insertedText == '\n';
    controller.remapBoundaries(
      oldValue,
      normalizedValue,
      insertedNewlinesAreBoundaries: !internalLineBreak,
    );
    return normalizedValue;
  }

  TextEditingValue _committedImeValue(
    TextEditingValue oldValue,
    TextEditingValue newValue,
    _TextReplacement replacement,
  ) {
    if (oldValue.text == newValue.text) {
      final composingText = oldValue.composing.textInside(oldValue.text);
      if (_containsLineBreak(composingText)) {
        final committedText = _withoutLineBreaks(composingText);
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
    if (_containsLineBreak(replacement.insertedText)) {
      final committedText = _withoutLineBreaks(replacement.insertedText);
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
    return newValue;
  }

  bool _containsLineBreak(String value) => value.contains('\n');

  String _withoutLineBreaks(String value) => value.replaceAll('\n', '');

  TextEditingValue _normalizeLineEndings(TextEditingValue value) {
    if (!value.text.contains('\r')) return value;

    int normalizedOffset(int offset) {
      if (offset < 0) return offset;
      return value.text
          .substring(0, offset.clamp(0, value.text.length))
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .length;
    }

    final text = value.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: normalizedOffset(value.selection.baseOffset),
        extentOffset: normalizedOffset(value.selection.extentOffset),
        affinity: value.selection.affinity,
        isDirectional: value.selection.isDirectional,
      ),
      composing: value.composing.isValid
          ? TextRange(
              start: normalizedOffset(value.composing.start),
              end: normalizedOffset(value.composing.end),
            )
          : TextRange.empty,
    );
  }
}

_TextReplacement _replacementBetween(String oldText, String newText) {
  var prefix = 0;
  final sharedLength = math.min(oldText.length, newText.length);
  while (prefix < sharedLength &&
      oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
    prefix++;
  }

  var oldSuffix = oldText.length;
  var newSuffix = newText.length;
  while (oldSuffix > prefix &&
      newSuffix > prefix &&
      oldText.codeUnitAt(oldSuffix - 1) == newText.codeUnitAt(newSuffix - 1)) {
    oldSuffix--;
    newSuffix--;
  }

  return _TextReplacement(
    start: prefix,
    end: oldSuffix,
    insertedText: newText.substring(prefix, newSuffix),
  );
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

class _EditorSnapshot {
  const _EditorSnapshot({
    required this.text,
    required this.boundaryOffsets,
    required this.selection,
  });

  final String text;
  final List<int> boundaryOffsets;
  final TextSelection selection;

  _EditorSnapshot copyWith({TextSelection? selection}) => _EditorSnapshot(
        text: text,
        boundaryOffsets: boundaryOffsets,
        selection: selection ?? this.selection,
      );
}
