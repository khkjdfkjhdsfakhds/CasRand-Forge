import 'dart:math' as math;

import 'package:flutter/material.dart';

class PromptTextHighlight {
  const PromptTextHighlight({required this.range, required this.style});

  final TextRange range;
  final TextStyle style;
}

/// Applies non-overlapping semantic ranges to an existing styled text tree.
///
/// Existing comment, composing and editor layout styles are retained; the
/// supplied highlight style only overrides the properties it specifies.
TextSpan applyPromptTextHighlights(
  TextSpan root,
  List<PromptTextHighlight> highlights,
) {
  if (highlights.isEmpty) return root;
  final ordered = List<PromptTextHighlight>.of(highlights)
    ..sort((left, right) => left.range.start.compareTo(right.range.start));
  final segments = <_TextSegment>[];
  _flattenSpan(root, 0, null, segments);
  if (segments.isEmpty) return root;

  final result = <InlineSpan>[];
  var highlightIndex = 0;
  for (final segment in segments) {
    while (highlightIndex < ordered.length &&
        ordered[highlightIndex].range.end <= segment.offset) {
      highlightIndex++;
    }
    result.addAll(_splitSegment(segment, ordered, highlightIndex));
  }
  return TextSpan(children: result);
}

void _flattenSpan(
  TextSpan span,
  int offset,
  TextStyle? inheritedStyle,
  List<_TextSegment> output,
) {
  final effectiveStyle =
      inheritedStyle == null ? span.style : inheritedStyle.merge(span.style);
  final text = span.text;
  if (text != null && text.isNotEmpty) {
    output.add(_TextSegment(offset, text, effectiveStyle));
    offset += text.length;
  }
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is! TextSpan) continue;
    _flattenSpan(child, offset, effectiveStyle, output);
    offset += _spanTextLength(child);
  }
}

int _spanTextLength(TextSpan span) {
  var length = span.text?.length ?? 0;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) length += _spanTextLength(child);
  }
  return length;
}

List<InlineSpan> _splitSegment(
  _TextSegment segment,
  List<PromptTextHighlight> highlights,
  int startIndex,
) {
  final result = <InlineSpan>[];
  final segmentEnd = segment.offset + segment.text.length;
  var position = segment.offset;

  for (var index = startIndex; index < highlights.length; index++) {
    final highlight = highlights[index];
    if (highlight.range.end <= position) continue;
    if (highlight.range.start >= segmentEnd) break;
    final start = math.max(position, highlight.range.start);
    final end = math.min(segmentEnd, highlight.range.end);
    if (start > position) {
      result.add(
        TextSpan(
          text: segment.text.substring(
            position - segment.offset,
            start - segment.offset,
          ),
          style: segment.style,
        ),
      );
    }
    result.add(
      TextSpan(
        text: segment.text.substring(
          start - segment.offset,
          end - segment.offset,
        ),
        style: (segment.style ?? const TextStyle()).merge(highlight.style),
      ),
    );
    position = end;
  }

  if (position < segmentEnd) {
    result.add(
      TextSpan(
        text: segment.text.substring(position - segment.offset),
        style: segment.style,
      ),
    );
  }
  return result.isEmpty
      ? [TextSpan(text: segment.text, style: segment.style)]
      : result;
}

class _TextSegment {
  const _TextSegment(this.offset, this.text, this.style);

  final int offset;
  final String text;
  final TextStyle? style;
}
