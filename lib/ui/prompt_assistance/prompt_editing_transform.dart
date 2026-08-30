import 'package:flutter/services.dart';

/// Which prompt surface is being edited by a text transformation.
///
/// A fixed prompt is one final prompt and therefore treats top-level newlines
/// as separators.  A cascaded entry is one random-selection candidate; its
/// caller supplies the entry range and newlines inside that range stay part of
/// the candidate (only commas separate tags).
enum PromptEditingScope {
  fixedPrompt,
  cascadedEntry,
}

enum PromptWeightDirection { increase, decrease }

enum PromptMoveDirection { backward, forward }

/// The complete result of a shared prompt text edit.
///
/// Returning a [TextEditingValue] keeps selection and composing state together
/// so adapters can assign it to their controller as one undoable edit.
class PromptTextEditResult {
  final TextEditingValue value;
  final bool changed;

  const PromptTextEditResult({required this.value, required this.changed});

  static PromptTextEditResult unchanged(TextEditingValue value) =>
      PromptTextEditResult(value: value, changed: false);
}

/// Stateless weight and position transforms used by both prompt editor types.
///
/// The methods intentionally do not know about widgets, controllers, settings,
/// or persistence.  Adapters provide the current value and selection and can
/// pass the resulting value to their existing history mechanism.
class PromptEditingTransform {
  const PromptEditingTransform._();

  static const double weightStep = 0.1;
  static const double minimumWeight = -10;
  static const double maximumWeight = 10;

  /// Adjusts the complete tag/group containing [value.selection].
  ///
  /// [editableRange] is useful for cascaded editors: pass the current entry's
  /// range to prevent the operation from touching neighbouring entries.  For
  /// fixed prompts it may be omitted and the whole document is used.
  static PromptTextEditResult adjustWeight(
    TextEditingValue value, {
    required PromptWeightDirection direction,
    PromptEditingScope scope = PromptEditingScope.fixedPrompt,
    TextRange? editableRange,
  }) {
    if (_isComposing(value) || !_hasUsableSelection(value)) {
      return PromptTextEditResult.unchanged(value);
    }
    final range = _effectiveRange(value.text, editableRange);
    final items = _scanItems(
      value.text,
      range,
      splitOnNewlines: scope == PromptEditingScope.fixedPrompt,
    );
    final item = _itemForSelection(items, value.selection);
    if (item == null || item.isComment) {
      return PromptTextEditResult.unchanged(value);
    }

    final oldSegment = value.text.substring(item.start, item.end);
    final syntax = _parseWeightSyntax(oldSegment);
    if (syntax == null) return PromptTextEditResult.unchanged(value);

    final delta =
        direction == PromptWeightDirection.increase ? weightStep : -weightStep;
    final next = syntax.adjusted(delta);
    if (next.source == oldSegment) {
      return PromptTextEditResult.unchanged(value);
    }

    final newText = value.text.replaceRange(item.start, item.end, next.source);
    final newSelection = _mapSelectionThroughWeightEdit(
      value.selection,
      item,
      syntax,
      next,
    );
    return PromptTextEditResult(
      value: value.copyWith(
        text: newText,
        selection: newSelection,
        composing: TextRange.empty,
      ),
      changed: true,
    );
  }

  /// Exchanges the complete tag/group containing [value.selection] with its
  /// previous or next valid item.
  ///
  /// Separators, whitespace, comments and line endings remain byte-for-byte
  /// where they were.  Only the two item spans are exchanged, so the caret
  /// follows the moved item and repeated shortcuts keep acting on it.
  static PromptTextEditResult move(
    TextEditingValue value, {
    required PromptMoveDirection direction,
    PromptEditingScope scope = PromptEditingScope.fixedPrompt,
    TextRange? editableRange,
  }) {
    if (_isComposing(value) || !_hasUsableSelection(value)) {
      return PromptTextEditResult.unchanged(value);
    }
    final range = _effectiveRange(value.text, editableRange);
    final items = _scanItems(
      value.text,
      range,
      splitOnNewlines: scope == PromptEditingScope.fixedPrompt,
    );
    final index = items.indexWhere(
      (item) => !item.isComment && _containsSelection(item, value.selection),
    );
    if (index < 0) return PromptTextEditResult.unchanged(value);

    final step = direction == PromptMoveDirection.backward ? -1 : 1;
    var neighbourIndex = index + step;
    while (neighbourIndex >= 0 && neighbourIndex < items.length) {
      if (!items[neighbourIndex].isComment) break;
      neighbourIndex += step;
    }
    if (neighbourIndex < 0 || neighbourIndex >= items.length) {
      return PromptTextEditResult.unchanged(value);
    }

    final current = items[index];
    final neighbour = items[neighbourIndex];
    final currentText = value.text.substring(current.start, current.end);
    final neighbourText = value.text.substring(neighbour.start, neighbour.end);
    if (currentText == neighbourText && current.start == neighbour.start) {
      return PromptTextEditResult.unchanged(value);
    }

    final edits = <_Replacement>[
      _Replacement(start: current.start, end: current.end, text: neighbourText),
      _Replacement(
          start: neighbour.start, end: neighbour.end, text: currentText),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final newText = _applyReplacements(value.text, edits);
    final mappedSelection = _mapSelectionForMove(
      value.selection,
      current,
      neighbour,
      currentText.length,
      neighbourText.length,
    );
    return PromptTextEditResult(
      value: value.copyWith(
        text: newText,
        selection: mappedSelection,
        composing: TextRange.empty,
      ),
      changed: true,
    );
  }
}

class _PromptItem {
  final int start;
  final int end;
  final bool isComment;

  const _PromptItem(
      {required this.start, required this.end, this.isComment = false});
}

class _Replacement {
  final int start;
  final int end;
  final String text;

  const _Replacement(
      {required this.start, required this.end, required this.text});
}

class _WeightSyntax {
  final String source;
  final double? numericWeight;
  final String body;
  final int bodyStart;
  final int bodyEnd;

  /// Complete outer wrappers, from outside to inside.  Keeping the sequence
  /// (rather than only counts) means mixed nested forms such as `{[tag]}` are
  /// preserved when the outer wrapper is adjusted.
  final List<String> wrappers;
  final bool invalid;

  const _WeightSyntax({
    required this.source,
    required this.numericWeight,
    required this.body,
    required this.bodyStart,
    required this.bodyEnd,
    required this.wrappers,
    required this.invalid,
  });

  String get _trimmed => source.trim();

  _WeightSyntax adjusted(double delta) {
    if (invalid) return this;
    if (numericWeight != null) {
      final weight = _roundWeight(
        (numericWeight! + delta).clamp(
          PromptEditingTransform.minimumWeight,
          PromptEditingTransform.maximumWeight,
        ),
      );
      if (weight == 1) {
        return _WeightSyntax(
          source: body,
          numericWeight: null,
          body: body,
          bodyStart: 0,
          bodyEnd: body.length,
          wrappers: const [],
          invalid: false,
        );
      }
      final formatted = _formatWeight(weight);
      final replacement = '$formatted::${_safeNumericWeightBody(body)}::';
      return _WeightSyntax(
        source: replacement,
        numericWeight: weight,
        body: body,
        bodyStart: formatted.length + 2,
        bodyEnd: formatted.length + 2 + body.length,
        wrappers: const [],
        invalid: false,
      );
    }

    if (wrappers.isNotEmpty && wrappers.first == '{') {
      final nextWrappers = List<String>.of(wrappers);
      if (delta > 0) {
        nextWrappers.insert(0, '{');
      } else {
        nextWrappers.removeAt(0);
      }
      final core = body;
      final wrapped = _wrapWithWrappers(nextWrappers, core);
      final coreStart = nextWrappers.length;
      return _WeightSyntax(
        source: wrapped,
        numericWeight: null,
        body: core,
        bodyStart: coreStart,
        bodyEnd: coreStart + core.length,
        wrappers: nextWrappers,
        invalid: false,
      );
    }

    if (wrappers.isNotEmpty && wrappers.first == '[') {
      // Square brackets are inverse emphasis: increasing removes a level,
      // decreasing adds one.
      final nextWrappers = List<String>.of(wrappers);
      if (delta > 0) {
        nextWrappers.removeAt(0);
      } else {
        nextWrappers.insert(0, '[');
      }
      final core = body;
      final wrapped = _wrapWithWrappers(nextWrappers, core);
      final coreStart = nextWrappers.length;
      return _WeightSyntax(
        source: wrapped,
        numericWeight: null,
        body: core,
        bodyStart: coreStart,
        bodyEnd: coreStart + core.length,
        wrappers: nextWrappers,
        invalid: false,
      );
    }

    final weight = _roundWeight(
      (1 + delta).clamp(
        PromptEditingTransform.minimumWeight,
        PromptEditingTransform.maximumWeight,
      ),
    );
    final formatted = _formatWeight(weight);
    final replacement = '$formatted::${_safeNumericWeightBody(_trimmed)}::';
    return _WeightSyntax(
      source: replacement,
      numericWeight: weight,
      body: _trimmed,
      bodyStart: formatted.length + 2,
      bodyEnd: formatted.length + 2 + _trimmed.length,
      wrappers: const [],
      invalid: false,
    );
  }
}

bool _isComposing(TextEditingValue value) {
  final composing = value.composing;
  return composing.isValid && !composing.isCollapsed;
}

bool _hasUsableSelection(TextEditingValue value) {
  final selection = value.selection;
  return selection.isValid &&
      selection.start >= 0 &&
      selection.end <= value.text.length;
}

TextRange _effectiveRange(String text, TextRange? range) {
  final candidate = range ?? TextRange(start: 0, end: text.length);
  final start = candidate.start.clamp(0, text.length);
  final end = candidate.end.clamp(start, text.length);
  return TextRange(start: start, end: end);
}

bool _containsSelection(_PromptItem item, TextSelection selection) {
  if (!selection.isValid || selection.start != selection.end) return false;
  return selection.extentOffset >= item.start &&
      selection.extentOffset <= item.end;
}

_PromptItem? _itemForSelection(
  List<_PromptItem> items,
  TextSelection selection,
) {
  if (!selection.isValid || !selection.isCollapsed) return null;
  for (final item in items) {
    if (item.isComment) continue;
    if (_containsSelection(item, selection)) return item;
  }
  return null;
}

List<_PromptItem> _scanItems(
  String text,
  TextRange range, {
  required bool splitOnNewlines,
}) {
  if (range.start == range.end) return const [];
  final items = <_PromptItem>[];
  var segmentStart = range.start;
  final delimiters = <String>[];
  var numericGroup = false;
  var numericPrefixStart = range.start;
  var lineStart = range.start;
  var lineComment = false;

  void emit(int separatorStart, {bool comment = false}) {
    final rawStart = segmentStart;
    final rawEnd = separatorStart;
    var start = rawStart;
    var end = rawEnd;
    while (start < end && _isPromptWhitespace(text[start])) {
      start++;
    }
    while (end > start && _isPromptWhitespace(text[end - 1])) {
      end--;
    }
    if (start < end) {
      items.add(_PromptItem(start: start, end: end, isComment: comment));
    }
    segmentStart = separatorStart + 1;
    delimiters.clear();
    numericGroup = false;
    numericPrefixStart = segmentStart;
  }

  for (var index = range.start; index < range.end; index++) {
    final character = text[index];
    if (character == '\n') {
      if (lineComment) {
        // Comment lines are their own non-target item even in a cascaded
        // entry, where ordinary internal newlines are intentionally not
        // separators.  This prevents a following comma-delimited tag from
        // absorbing the comment into its editable span.
        emit(index, comment: true);
      } else if (splitOnNewlines && delimiters.isEmpty && !numericGroup) {
        emit(index);
      }
      lineStart = index + 1;
      lineComment = false;
      continue;
    }

    if (delimiters.isEmpty &&
        !numericGroup &&
        _isCommentLineStart(text, lineStart, index)) {
      if (lineStart > segmentStart) {
        // A comment may follow an ordinary internal newline in a cascaded
        // entry.  Close the preceding tag before starting the comment span;
        // the newline itself remains an untouched separator in the source.
        emit(lineStart - 1);
      }
      lineComment = true;
    }
    if (lineComment) continue;

    if (numericGroup) {
      if (character == ':' && index + 1 < range.end && text[index + 1] == ':') {
        numericGroup = false;
        index++;
      }
      continue;
    }

    if (delimiters.isEmpty &&
        character == ':' &&
        index + 1 < range.end &&
        text[index + 1] == ':') {
      final prefix = text.substring(numericPrefixStart, index).trim();
      if (RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$').hasMatch(prefix)) {
        numericGroup = true;
        index++;
        continue;
      }
    }

    if (delimiters.isEmpty &&
        (character == ',' ||
            character == '，' ||
            (splitOnNewlines && character == '\n'))) {
      emit(index);
      continue;
    }
    if (character == '(' || character == '{' || character == '[') {
      delimiters.add(character);
    } else if (character == ')' || character == '}' || character == ']') {
      if (delimiters.isNotEmpty &&
          _matchingDelimiter(delimiters.last, character)) {
        delimiters.removeLast();
      } else {
        // Keep scanning the item.  The weight parser rejects this item as
        // invalid instead of destructively normalizing it.
        delimiters.add('!');
      }
    }
    if (delimiters.isEmpty && text[index] != ' ' && text[index] != '\t') {
      numericPrefixStart = segmentStart;
    }
  }

  var start = segmentStart;
  var end = range.end;
  while (start < end && _isPromptWhitespace(text[start])) {
    start++;
  }
  while (end > start && _isPromptWhitespace(text[end - 1])) {
    end--;
  }
  if (start < end) {
    items.add(_PromptItem(start: start, end: end, isComment: lineComment));
  }
  return items;
}

bool _isCommentLineStart(String text, int lineStart, int index) {
  var cursor = lineStart;
  while (cursor < index && _isPromptWhitespace(text[cursor])) {
    cursor++;
  }
  return cursor <= index && cursor < text.length && text[cursor] == '#';
}

bool _isPromptWhitespace(String value) =>
    value == ' ' || value == '\t' || value == '\r' || value == '　';

String _safeNumericWeightBody(String body) {
  if (body.isNotEmpty) {
    final last = body.codeUnitAt(body.length - 1);
    if (last >= 0x30 && last <= 0x39) return '$body ';
  }
  return body;
}

bool _matchingDelimiter(String opening, String closing) =>
    (opening == '(' && closing == ')') ||
    (opening == '{' && closing == '}') ||
    (opening == '[' && closing == ']');

_WeightSyntax? _parseWeightSyntax(String source) {
  final leading = source.length - source.trimLeft().length;
  final trimmed = source.trim();
  if (trimmed.isEmpty || !_balanced(trimmed)) return null;

  final numericPrefix = RegExp(
    r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))::',
  ).firstMatch(trimmed);
  if (numericPrefix != null) {
    final close = trimmed.lastIndexOf('::');
    final bodyStart = numericPrefix.end;
    if (close <= bodyStart || close != trimmed.length - 2) return null;
    final body = trimmed.substring(bodyStart, close);
    if (body.trim().isEmpty || !_balanced(body)) return null;
    final numeric = double.tryParse(numericPrefix.group(1)!);
    if (numeric == null || numeric.isNaN || numeric.isInfinite) return null;
    return _WeightSyntax(
      source: source,
      numericWeight: numeric,
      body: body,
      bodyStart: leading + bodyStart,
      bodyEnd: leading + close,
      wrappers: const [],
      invalid: false,
    );
  }

  // A stray numeric delimiter is likely an incomplete syntax.  Leave it
  // untouched rather than wrapping it in another numeric group.
  if (trimmed.contains('::')) return null;

  var core = trimmed;
  final wrappers = <String>[];
  while (core.length >= 2) {
    if (_isCompleteOuterWrapper(core, '{', '}')) {
      wrappers.add('{');
      core = core.substring(1, core.length - 1);
      continue;
    }
    if (_isCompleteOuterWrapper(core, '[', ']')) {
      wrappers.add('[');
      core = core.substring(1, core.length - 1);
      continue;
    }
    break;
  }
  if (core.trim().isEmpty || !_balanced(core)) return null;
  final coreStart = trimmed.indexOf(core);
  return _WeightSyntax(
    source: source,
    numericWeight: null,
    body: core,
    bodyStart: leading + coreStart,
    bodyEnd: leading + coreStart + core.length,
    wrappers: wrappers,
    invalid: false,
  );
}

String _wrapWithWrappers(List<String> wrappers, String core) {
  var result = core;
  for (final opening in wrappers.reversed) {
    final closing = switch (opening) {
      '{' => '}',
      '[' => ']',
      '(' => ')',
      _ => opening,
    };
    result = '$opening$result$closing';
  }
  return result;
}

bool _isCompleteOuterWrapper(String value, String opening, String closing) {
  if (value.length < 2 ||
      value[0] != opening ||
      value[value.length - 1] != closing) {
    return false;
  }
  var depth = 0;
  final stack = <String>[];
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character == '(' || character == '{' || character == '[') {
      stack.add(character);
      depth++;
    } else if (character == ')' || character == '}' || character == ']') {
      if (stack.isEmpty || !_matchingDelimiter(stack.removeLast(), character)) {
        return false;
      }
      depth--;
      if (depth == 0 && index != value.length - 1) return false;
    }
  }
  return stack.isEmpty;
}

bool _balanced(String value) {
  final stack = <String>[];
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character == '(' || character == '{' || character == '[') {
      stack.add(character);
      continue;
    }
    if (character == ')' || character == '}' || character == ']') {
      if (stack.isEmpty || !_matchingDelimiter(stack.removeLast(), character)) {
        return false;
      }
    }
  }
  return stack.isEmpty;
}

double _roundWeight(num value) {
  final rounded = (value.toDouble() * 100).roundToDouble() / 100;
  return rounded == -0.0 ? 0.0 : rounded;
}

String _formatWeight(double value) {
  final rounded = _roundWeight(value);
  if (rounded == rounded.roundToDouble()) return rounded.toInt().toString();
  return rounded
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.\$'), '');
}

String _applyReplacements(String source, List<_Replacement> replacements) {
  final buffer = StringBuffer();
  var cursor = 0;
  for (final replacement in replacements) {
    buffer
      ..write(source.substring(cursor, replacement.start))
      ..write(replacement.text);
    cursor = replacement.end;
  }
  buffer.write(source.substring(cursor));
  return buffer.toString();
}

TextSelection _mapSelectionForMove(
  TextSelection selection,
  _PromptItem current,
  _PromptItem neighbour,
  int currentLength,
  int neighbourLength,
) {
  // When the current item is moved right, the longer/shorter neighbour's
  // replacement occurs after it and the target start shifts by the length
  // delta of the earlier replacement.  Moving left keeps the target at the
  // current item's original start.
  final targetStart = current.start < neighbour.start
      ? neighbour.start + neighbourLength - currentLength
      : neighbour.start;

  int mapOffset(int offset) {
    final relative = (offset - current.start).clamp(0, currentLength);
    // The offset is relative to the item being moved, not to the neighbour's
    // replacement text.  Do not clamp it to [neighbourLength]: when a longer
    // item moves over a shorter one (for example `long, a`), the tail of the
    // caret range still belongs to the moved item after the swap.
    return targetStart + relative;
  }

  return TextSelection(
    baseOffset: mapOffset(selection.baseOffset),
    extentOffset: mapOffset(selection.extentOffset),
    affinity: selection.affinity,
    isDirectional: selection.isDirectional,
  );
}

TextSelection _mapSelectionThroughWeightEdit(
  TextSelection selection,
  _PromptItem item,
  _WeightSyntax oldSyntax,
  _WeightSyntax newSyntax,
) {
  int mapOffset(int offset) {
    final oldRelative = (offset - item.start).clamp(0, oldSyntax.source.length);
    final oldBodyStart = oldSyntax.bodyStart;
    final oldBodyEnd = oldSyntax.bodyEnd;
    final newBodyStart = newSyntax.bodyStart;
    final newBodyEnd = newSyntax.bodyEnd;
    if (oldRelative < oldBodyStart) {
      return item.start + oldRelative.clamp(0, newBodyStart);
    }
    if (oldRelative <= oldBodyEnd) {
      final bodyRelative = oldRelative - oldBodyStart;
      return item.start +
          newBodyStart +
          bodyRelative.clamp(0, newBodyEnd - newBodyStart);
    }
    final trailing = oldRelative - oldBodyEnd;
    return item.start +
        newBodyEnd +
        trailing.clamp(0, newSyntax.source.length - newBodyEnd);
  }

  return TextSelection(
    baseOffset: mapOffset(selection.baseOffset),
    extentOffset: mapOffset(selection.extentOffset),
    affinity: selection.affinity,
    isDirectional: selection.isDirectional,
  );
}
