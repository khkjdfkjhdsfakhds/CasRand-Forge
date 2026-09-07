import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_text_highlighting.dart';

/// Shared NovelAI numeric-weight parsing and safe-ending behavior.
abstract final class PromptWeightSyntax {
  static const Color increaseBackground = Color.fromRGBO(184, 55, 0, 0.275);
  static const Color decreaseBackground = Color.fromRGBO(4, 102, 206, 0.325);
  static const Color delimiterBackground = Color.fromRGBO(0, 151, 7, 0.5);

  static final RegExp _numericOpener = RegExp(
    r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)::',
  );

  /// Describes the semantic ranges NovelAI displays for numeric weights.
  static PromptWeightAnalysis analyze(String text) {
    final spans = <PromptWeightSpan>[];
    final stack = <PromptWeightKind?>[];
    PromptWeightKind? activeKind;
    var segmentStart = 0;

    void flush(int end) {
      if (activeKind != null && end > segmentStart) {
        _addSpan(spans, TextRange(start: segmentStart, end: end), activeKind);
      }
    }

    for (final token in _scan(text)) {
      flush(token.start);
      switch (token.type) {
        case _WeightTokenType.comment:
          activeKind = null;
        case _WeightTokenType.lineBreak:
          stack.clear();
          activeKind = null;
        case _WeightTokenType.opener:
          final kind = token.weightKind;
          _addSpan(
            spans,
            TextRange(start: token.start, end: token.end),
            kind ?? PromptWeightKind.delimiter,
          );
          stack.add(kind);
          activeKind = kind;
        case _WeightTokenType.closer:
          if (stack.isNotEmpty) {
            _addSpan(
              spans,
              TextRange(start: token.start, end: token.end),
              PromptWeightKind.delimiter,
            );
            stack.removeLast();
          }
          activeKind = null;
      }
      segmentStart = token.end;
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
    for (final token in _scan(text)) {
      switch (token.type) {
        case _WeightTokenType.comment:
          break;
        case _WeightTokenType.lineBreak:
          stack.clear();
        case _WeightTokenType.opener:
          if (stack.isNotEmpty &&
              !_startsAtPromptBoundary(text, token.start, stack)) {
            result.add(
              _AmbiguousClosing(
                start: token.start,
                end: token.end,
                insertionOffset: token.end - 2,
              ),
            );
          }
          stack.add(token.end);
        case _WeightTokenType.closer:
          if (stack.isNotEmpty) stack.removeLast();
      }
    }
    return result;
  }

  static Iterable<_WeightToken> _scan(String text) sync* {
    var offset = 0;
    while (offset < text.length) {
      final commentEnd = _commentLineEnd(text, offset);
      if (commentEnd != null) {
        yield _WeightToken(
          type: _WeightTokenType.comment,
          start: offset,
          end: commentEnd,
        );
        offset = commentEnd;
        continue;
      }
      if (text.codeUnitAt(offset) == 0x0A) {
        yield _WeightToken(
          type: _WeightTokenType.lineBreak,
          start: offset,
          end: offset + 1,
        );
        offset++;
        continue;
      }
      final opener = _numericOpener.matchAsPrefix(text, offset);
      if (opener != null) {
        final weight = double.parse(text.substring(offset, opener.end - 2));
        yield _WeightToken(
          type: _WeightTokenType.opener,
          start: offset,
          end: opener.end,
          weightKind: weight > 1
              ? PromptWeightKind.increase
              : weight < 1
                  ? PromptWeightKind.decrease
                  : null,
        );
        offset = opener.end;
        continue;
      }
      if (offset + 1 < text.length && text.startsWith('::', offset)) {
        yield _WeightToken(
          type: _WeightTokenType.closer,
          start: offset,
          end: offset + 2,
        );
        offset += 2;
        continue;
      }
      offset++;
    }
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

enum _WeightTokenType { opener, closer, lineBreak, comment }

class _WeightToken {
  const _WeightToken({
    required this.type,
    required this.start,
    required this.end,
    this.weightKind,
  });

  final _WeightTokenType type;
  final int start;
  final int end;
  final PromptWeightKind? weightKind;
}
