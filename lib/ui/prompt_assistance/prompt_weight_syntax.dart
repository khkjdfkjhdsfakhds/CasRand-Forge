import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_text_highlighting.dart';

/// Shared NovelAI numeric-weight parsing and safe-ending behavior.
abstract final class PromptWeightSyntax {
  static const Color increaseBackground = Color(0x66B83700);
  static const Color decreaseBackground = Color(0x660466CE);
  static const Color delimiterBackground = Color(0x73009707);

  static final RegExp _numericOpener = RegExp(
    r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)::',
  );

  /// Describes the semantic ranges NovelAI displays for numeric weights.
  static PromptWeightAnalysis analyze(String text) {
    final spans = <PromptWeightSpan>[];
    final stack = <PromptWeightKind?>[];
    PromptWeightKind? activeKind;
    var segmentStart = 0;
    var offset = 0;

    void flush(int end) {
      if (activeKind != null && end > segmentStart) {
        _addSpan(spans, TextRange(start: segmentStart, end: end), activeKind);
      }
    }

    while (offset < text.length) {
      final commentEnd = _commentLineEnd(text, offset);
      if (commentEnd != null) {
        flush(offset);
        activeKind = null;
        offset = commentEnd;
        segmentStart = offset;
        continue;
      }

      if (text.codeUnitAt(offset) == 0x0A) {
        flush(offset);
        stack.clear();
        activeKind = null;
        offset++;
        segmentStart = offset;
        continue;
      }

      final opener = _numericOpener.matchAsPrefix(text, offset);
      if (opener != null) {
        flush(offset);
        final end = opener.end;
        final rawWeight = text.substring(offset, end - 2);
        final weight = double.parse(rawWeight);
        final kind = weight > 1
            ? PromptWeightKind.increase
            : weight < 1
                ? PromptWeightKind.decrease
                : null;
        _addSpan(
          spans,
          TextRange(start: offset, end: end),
          kind ?? PromptWeightKind.delimiter,
        );
        stack.add(kind);
        activeKind = kind;
        offset = end;
        segmentStart = offset;
        continue;
      }

      if (offset + 1 < text.length && text.startsWith('::', offset)) {
        flush(offset);
        if (stack.isNotEmpty) {
          _addSpan(
            spans,
            TextRange(start: offset, end: offset + 2),
            PromptWeightKind.delimiter,
          );
          stack.removeLast();
        }
        activeKind = null;
        offset += 2;
        segmentStart = offset;
        continue;
      }
      offset++;
    }
    flush(text.length);
    return PromptWeightAnalysis(List.unmodifiable(spans));
  }

  static TextSpan applyHighlights(
    TextSpan base,
    String text,
  ) {
    final analysis = analyze(text);
    return applyPromptTextHighlights(
      base,
      [
        for (final span in analysis.spans)
          PromptTextHighlight(
            range: span.range,
            style: TextStyle(
              backgroundColor: switch (span.kind) {
                PromptWeightKind.increase => increaseBackground,
                PromptWeightKind.decrease => decreaseBackground,
                PromptWeightKind.delimiter => delimiterBackground,
              },
            ),
          ),
      ],
    );
  }

  /// Inserts the NovelAI-compatible separator before ambiguous closing `::`
  /// sequences throughout [value].
  static TextEditingValue normalizeAll(TextEditingValue value) {
    if (_hasComposingText(value)) return value;
    final insertions = _ambiguousClosings(value.text)
        .map((candidate) => candidate.insertionOffset)
        .toList(growable: false);
    return _applyInsertions(value, insertions);
  }

  static String normalizeText(String text) {
    return normalizeAll(TextEditingValue(text: text)).text;
  }

  /// Normalizes only ambiguity introduced or touched by the edit from
  /// [oldValue] to [newValue]. Existing saved text elsewhere is left intact.
  static TextEditingValue normalizeEdit(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (_hasComposingText(newValue) || oldValue.text == newValue.text) {
      return newValue;
    }
    final changed = _changedRange(oldValue.text, newValue.text);
    final insertions = _ambiguousClosings(newValue.text)
        .where(
          (candidate) =>
              candidate.start <= changed.end && candidate.end >= changed.start,
        )
        .map((candidate) => candidate.insertionOffset)
        .toList(growable: false);
    return _applyInsertions(newValue, insertions);
  }

  static TextEditingValue _applyInsertions(
    TextEditingValue value,
    List<int> insertions,
  ) {
    if (insertions.isEmpty) return value;

    final buffer = StringBuffer();
    var sourceOffset = 0;
    for (final offset in insertions) {
      buffer
        ..write(value.text.substring(sourceOffset, offset))
        ..write(' ');
      sourceOffset = offset;
    }
    buffer.write(value.text.substring(sourceOffset));

    return value.copyWith(
      text: buffer.toString(),
      selection: _shiftSelection(value.selection, insertions),
      composing: TextRange.empty,
    );
  }

  static List<_AmbiguousClosing> _ambiguousClosings(String text) {
    final result = <_AmbiguousClosing>[];
    final stack = <int>[];
    var offset = 0;
    while (offset < text.length) {
      final commentEnd = _commentLineEnd(text, offset);
      if (commentEnd != null) {
        offset = commentEnd;
        continue;
      }
      if (text.codeUnitAt(offset) == 0x0A) {
        stack.clear();
        offset++;
        continue;
      }
      final opener = _numericOpener.matchAsPrefix(text, offset);
      if (opener != null) {
        final openerEnd = opener.end;
        if (stack.isNotEmpty && !_startsAtPromptBoundary(text, offset, stack)) {
          result.add(
            _AmbiguousClosing(
              start: offset,
              end: openerEnd,
              insertionOffset: openerEnd - 2,
            ),
          );
        }
        stack.add(openerEnd);
        offset = openerEnd;
        continue;
      }
      if (offset + 1 < text.length && text.startsWith('::', offset)) {
        if (stack.isNotEmpty) stack.removeLast();
        offset += 2;
        continue;
      }
      offset++;
    }
    return result;
  }

  static void _addSpan(
    List<PromptWeightSpan> spans,
    TextRange range,
    PromptWeightKind kind,
  ) {
    if (range.isCollapsed) return;
    if (spans case [..., final last]
        when last.kind == kind && last.range.end == range.start) {
      spans[spans.length - 1] = PromptWeightSpan(
        range: TextRange(start: last.range.start, end: range.end),
        kind: kind,
      );
      return;
    }
    spans.add(PromptWeightSpan(range: range, kind: kind));
  }

  static int? _commentLineEnd(String text, int offset) {
    if (offset != 0 && text.codeUnitAt(offset - 1) != 0x0A) return null;
    var contentStart = offset;
    while (contentStart < text.length) {
      final codeUnit = text.codeUnitAt(contentStart);
      if (codeUnit != 0x20 && codeUnit != 0x09) break;
      contentStart++;
    }
    if (contentStart >= text.length || text.codeUnitAt(contentStart) != 0x23) {
      return null;
    }
    final newline = text.indexOf('\n', contentStart);
    return newline == -1 ? text.length : newline;
  }

  static ({int start, int end}) _changedRange(
    String oldText,
    String newText,
  ) {
    var start = 0;
    final sharedLength =
        oldText.length < newText.length ? oldText.length : newText.length;
    while (start < sharedLength && oldText[start] == newText[start]) {
      start++;
    }

    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > start &&
        newEnd > start &&
        oldText[oldEnd - 1] == newText[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    return (start: start, end: newEnd);
  }

  static bool _startsAtPromptBoundary(
    String text,
    int offset,
    List<int> stack,
  ) {
    if (offset == stack.last) return false;
    if (offset == 0) return true;
    final previous = text.codeUnitAt(offset - 1);
    return switch (previous) {
      0x09 || // tab
      0x0A || // line feed
      0x0D || // carriage return
      0x20 || // space
      0x28 || // (
      0x2C || // ,
      0x3B || // ;
      0x5B || // [
      0x7B || // {
      0x7C || // |
      0x3001 || // 、
      0xFF0C || // ，
      0xFF1B =>
        true, // ；
      _ => false,
    };
  }

  static bool _hasComposingText(TextEditingValue value) {
    return value.composing.isValid && !value.composing.isCollapsed;
  }

  static TextSelection _shiftSelection(
    TextSelection selection,
    List<int> insertions,
  ) {
    int shift(int offset) {
      if (offset < 0) return offset;
      return offset + insertions.where((position) => position <= offset).length;
    }

    return TextSelection(
      baseOffset: shift(selection.baseOffset),
      extentOffset: shift(selection.extentOffset),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }
}

enum PromptWeightKind { increase, decrease, delimiter }

class PromptWeightSpan {
  const PromptWeightSpan({required this.range, required this.kind});

  final TextRange range;
  final PromptWeightKind kind;
}

class PromptWeightAnalysis {
  const PromptWeightAnalysis(this.spans);

  final List<PromptWeightSpan> spans;
}

class PromptWeightSafetyFormatter extends TextInputFormatter {
  const PromptWeightSafetyFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return PromptWeightSyntax.normalizeEdit(oldValue, newValue);
  }
}

class PromptWeightText extends StatelessWidget {
  const PromptWeightText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.softWrap = true,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow overflow;
  final bool softWrap;

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      PromptWeightSyntax.applyHighlights(
        TextSpan(text: text, style: baseStyle),
        text,
      ),
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
    );
  }
}

class _AmbiguousClosing {
  const _AmbiguousClosing({
    required this.start,
    required this.end,
    required this.insertionOffset,
  });

  final int start;
  final int end;
  final int insertionOffset;
}
