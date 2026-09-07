import 'package:flutter/services.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_weight_syntax.dart';

enum PromptEditingScope { fixedPrompt, cascadedEntry }

enum PromptWeightDirection { increase, decrease }

enum PromptMoveDirection { backward, forward }

class PromptTextEditResult {
  final TextEditingValue value;
  final bool changed;
  const PromptTextEditResult({required this.value, required this.changed});
  static PromptTextEditResult unchanged(TextEditingValue value) =>
      PromptTextEditResult(value: value, changed: false);
}

/// Lossless local edits: the parser locates source spans; it never serializes
/// or normalizes an unrelated part of the document.
class PromptEditingTransform {
  const PromptEditingTransform._();
  static const double weightStep = .1;
  static const double minimumWeight = -10;
  static const double maximumWeight = 10;

  static PromptTextEditResult adjustWeight(
    TextEditingValue value, {
    required PromptWeightDirection direction,
    PromptEditingScope scope = PromptEditingScope.fixedPrompt,
    TextRange? editableRange,
  }) {
    final target = _target(value, scope, editableRange);
    if (target == null) return PromptTextEditResult.unchanged(value);
    final (node, caret) = target;
    final group = node.weight;
    final delta =
        direction == PromptWeightDirection.increase ? weightStep : -weightStep;
    if (group != null) {
      final old =
          double.parse(value.text.substring(group.start, group.bodyStart - 2));
      final next =
          ((old + delta).clamp(minimumWeight, maximumWeight) * 10).round() / 10;
      if (next == old) return PromptTextEditResult.unchanged(value);
      final body = value.text.substring(group.bodyStart, group.bodyEnd);
      final prefix = next == 1 ? '' : '${_number(next)}::';
      final suffix =
          next == 1 ? '' : value.text.substring(group.bodyEnd, group.end);
      return _replace(
          value,
          group.start,
          group.end,
          '$prefix$body$suffix',
          group.start +
              prefix.length +
              (caret - group.bodyStart).clamp(0, body.length));
    }
    final body = value.text.substring(node.start, node.end);
    final prefix = '${_number(1 + delta)}::';
    final replacement = PromptWeightSyntax.normalizeText('$prefix$body::');
    return _replace(
        value,
        node.start,
        node.end,
        replacement,
        node.start +
            prefix.length +
            (caret - node.start).clamp(0, body.length));
  }

  static PromptTextEditResult move(
    TextEditingValue value, {
    required PromptMoveDirection direction,
    PromptEditingScope scope = PromptEditingScope.fixedPrompt,
    TextRange? editableRange,
  }) {
    final target = _target(value, scope, editableRange);
    if (target == null) return PromptTextEditResult.unchanged(value);
    final (leaf, caret) = target;
    var current = leaf;
    var parent = current.parent!;
    final originallyWrapped = parent.kind != _Kind.root;
    // A one-tag wrapper travels with its tag, as in the reference shortcut.
    if (parent.kind != _Kind.root && parent.children.length == 1) {
      current = parent;
      parent = current.parent!;
    }
    final siblings = parent.children;
    final index = siblings.indexOf(current);
    final step = direction == PromptMoveDirection.backward ? -1 : 1;
    final nextIndex = index + step;
    final text = value.text;
    final moved = text.substring(current.start, current.end);
    final relativeCaret = (caret - current.start).clamp(0, moved.length);
    if (nextIndex >= 0 && nextIndex < siblings.length) {
      final neighbour = siblings[nextIndex];
      final left = step < 0 ? neighbour : current;
      final right = step < 0 ? current : neighbour;
      final gap = text.substring(left.end, right.start);
      // Random choices and prompt chunks are boundaries, never neighbours.
      if (gap.contains('|')) return PromptTextEditResult.unchanged(value);
      if (!originallyWrapped &&
          neighbour.kind == _Kind.weight &&
          !gap.contains('#')) {
        final prefix = text.substring(neighbour.start, neighbour.bodyStart);
        final body = text.substring(neighbour.bodyStart, neighbour.bodyEnd);
        final close = text.substring(neighbour.bodyEnd, neighbour.end);
        final joining = _joiner(body, moved);
        final inside = step < 0 ? '$body$joining$moved' : '$moved$joining$body';
        final caretIn = prefix.length +
            (step < 0 ? body.length + joining.length : 0) +
            relativeCaret;
        return _replace(value, left.start, right.end, '$prefix$inside$close',
            left.start + caretIn);
      }
      final other = text.substring(neighbour.start, neighbour.end);
      // An open group moved before another item needs a local closing marker,
      // otherwise the next item would accidentally inherit its weight.
      final movedBefore = _closedForFollowing(current, moved);
      final otherBefore = _closedForFollowing(neighbour, other);
      final separator = gap.isEmpty ? ' ' : gap;
      final replacement = step < 0
          ? '$movedBefore$separator$other'
          : '$otherBefore$separator$moved';
      return _replace(
          value,
          left.start,
          right.end,
          replacement,
          left.start +
              (step < 0 ? 0 : otherBefore.length + separator.length) +
              relativeCaret);
    }
    if (parent.kind == _Kind.root ||
        parent.kind == _Kind.random ||
        parent.children.length < 2) {
      return PromptTextEditResult.unchanged(value);
    }
    final remainingStart = step < 0 ? siblings[1].start : parent.bodyStart;
    final remainingEnd =
        step > 0 ? siblings[siblings.length - 2].end : parent.bodyEnd;
    final removedGap = step < 0
        ? text.substring(current.end, remainingStart)
        : text.substring(remainingEnd, current.start);
    if (removedGap.contains('#') || removedGap.contains('|')) {
      return PromptTextEditResult.unchanged(value);
    }
    final remaining =
        (step < 0 ? text.substring(parent.bodyStart, current.start) : '') +
            text.substring(remainingStart, remainingEnd) +
            (step > 0 ? text.substring(current.end, parent.bodyEnd) : '');
    var wrapper = text.substring(parent.start, parent.bodyStart) +
        remaining +
        text.substring(parent.bodyEnd, parent.end);
    if (step > 0) wrapper = _closedForFollowing(parent, wrapper);
    if (parent.kind == _Kind.weight && parent.end > parent.bodyEnd) {
      wrapper = _appendWeightClose(wrapper.substring(0, wrapper.length - 2));
    }
    final separator = removedGap.isEmpty ? ', ' : removedGap;
    final replacement =
        step < 0 ? '$moved$separator$wrapper' : '$wrapper$separator$moved';
    return _replace(
        value,
        parent.start,
        parent.end,
        replacement,
        parent.start +
            (step < 0 ? 0 : wrapper.length + separator.length) +
            relativeCaret);
  }

  static String _closedForFollowing(_Node node, String source) =>
      node.kind == _Kind.weight && node.end == node.bodyEnd
          ? _appendWeightClose(source)
          : source;

  static String _appendWeightClose(String source) =>
      RegExp(r'\d\.?$').hasMatch(source) ? '$source ::' : '$source::';

  static String _joiner(String a, String b) =>
      a.trim().isEmpty || b.trim().isEmpty ? '' : ', ';
  static String _number(double n) =>
      n.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

  static PromptTextEditResult _replace(TextEditingValue value, int start,
      int end, String replacement, int caret) {
    final text = value.text.replaceRange(start, end, replacement);
    return PromptTextEditResult(
        value: value.copyWith(
            text: text,
            selection:
                TextSelection.collapsed(offset: caret.clamp(0, text.length)),
            composing: TextRange.empty),
        changed: text != value.text);
  }

  static (_Node, int)? _target(
      TextEditingValue value, PromptEditingScope scope, TextRange? range) {
    if (!value.selection.isValid ||
        value.selection.end > value.text.length ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return null;
    }
    final start = (range?.start ?? 0).clamp(0, value.text.length);
    final end =
        (range?.end ?? value.text.length).clamp(start, value.text.length);
    final caret = (value.selection.start + value.selection.end) ~/ 2;
    if (caret < start || caret > end) return null;
    final parser =
        _Parser(value.text, end, scope == PromptEditingScope.fixedPrompt);
    final root = _Node(_Kind.root, start, end, start, end);
    parser.sequence(root, start, null, 0);
    final node = parser.locate(root, caret);
    if (node == null) return null;
    node.weight = parser.indicatedWeight ?? node.weight;
    return (node, caret.clamp(node.start, node.end));
  }
}

enum _Kind { root, tag, weight, brace, random }

class _Node {
  final _Kind kind;
  final int start;
  int end;
  final int bodyStart;
  int bodyEnd;
  _Node? parent;
  _Node? weight;
  final children = <_Node>[];
  _Node(this.kind, this.start, this.end, this.bodyStart, this.bodyEnd);
  void add(_Node child) {
    child.parent = this;
    children.add(child);
  }
}

class _Parser {
  final String text;
  final int end;
  final bool splitLines;
  final comments = <TextRange>[];
  _Node? activeWeight;
  _Node? indicatedWeight;
  _Parser(this.text, this.end, this.splitLines);
  static final _space = RegExp(r'\s');
  static final _wordEnd = RegExp(r'[\p{L}\p{N}_.]', unicode: true);
  bool space(int i) => _space.hasMatch(text[i]);
  bool comment(int i) {
    if (text[i] != '#') return false;
    final line = text.lastIndexOf('\n', i == 0 ? 0 : i - 1) + 1;
    return text.substring(line, i).trim().isEmpty;
  }

  Match? opener(int i) {
    if (i > 0 && _wordEnd.hasMatch(text[i - 1])) return null;
    final match = PromptWeightSyntax.numericOpenerAt(text, i);
    return match != null && match.end <= end ? match : null;
  }

  int sequence(_Node parent, int cursor, String? close, int depth) {
    if (depth > 64) return end;
    var i = cursor;
    while (i < end) {
      if (close != null && text.startsWith(close, i)) {
        if (close == '::') activeWeight = null;
        parent.bodyEnd = i;
        parent.end = i + close.length;
        return parent.end;
      }
      if (text[i] == '\n') {
        activeWeight = null;
        if (splitLines && parent.kind == _Kind.weight) {
          parent.bodyEnd = i;
          parent.end = i;
          return i;
        }
      }
      if (comment(i)) {
        final next = text.indexOf('\n', i);
        final stop = next < 0 ? end : next.clamp(i, end);
        comments.add(TextRange(start: i, end: stop));
        i = stop;
        continue;
      }
      if (space(i) || text[i] == ',' || text[i] == '，') {
        i++;
        continue;
      }
      final weight = opener(i);
      final kind = weight != null
          ? _Kind.weight
          : text.startsWith('||', i)
              ? _Kind.random
              : '{[('.contains(text[i])
                  ? _Kind.brace
                  : null;
      if (kind != null) {
        final bodyStart = weight?.end ?? i + (kind == _Kind.random ? 2 : 1);
        final closing = weight != null
            ? '::'
            : kind == _Kind.random
                ? '||'
                : {'{': '}', '[': ']', '(': ')'}[text[i]]!;
        final node = _Node(kind, i, end, bodyStart, end);
        // Parentheses are an atomic tag (commas inside them are literal).
        if (text[i] == '(') {
          var j = bodyStart, nesting = 1;
          while (j < end && nesting > 0) {
            if (text[j] == '(') nesting++;
            if (text[j] == ')') nesting--;
            j++;
          }
          parent.add(_Node(_Kind.tag, i, j, i, j)..weight = activeWeight);
          i = j;
          continue;
        }
        parent.add(node);
        if (kind == _Kind.weight) activeWeight = node;
        i = sequence(node, bodyStart, closing, depth + 1);
        continue;
      }
      if (text.startsWith('::', i)) {
        activeWeight = null;
        i += 2;
        continue;
      }
      if ('|}]'.contains(text[i])) {
        i++;
        continue;
      }
      final start = i;
      while (i < end) {
        if ((close != null && text.startsWith(close, i)) ||
            text.startsWith('::', i) ||
            ',，{}[]|'.contains(text[i]) ||
            (splitLines && text[i] == '\n') ||
            comment(i)) {
          break;
        }
        if (i > start && opener(i) != null) break;
        i++;
      }
      var stop = i;
      while (stop > start && space(stop - 1)) {
        stop--;
      }
      if (stop > start) {
        parent.add(
            _Node(_Kind.tag, start, stop, start, stop)..weight = activeWeight);
      }
      if (i == start) i++;
    }
    parent.bodyEnd = end;
    parent.end = end;
    return end;
  }

  _Node? locate(_Node parent, int caret) {
    if (comments.any((c) => caret >= c.start && caret <= c.end)) return null;
    if (parent.kind == _Kind.weight &&
        ((caret >= parent.start && caret < parent.bodyStart) ||
            (caret >= parent.bodyEnd && caret < parent.end))) {
      indicatedWeight = parent;
    }
    final nodes = parent.children;
    if (nodes.isEmpty) return null;
    _Node? chosen;
    // An exact next-tag start wins over trailing-whitespace attachment.
    for (final n in nodes) {
      if (caret >= n.start && caret < n.end) {
        chosen = n;
        break;
      }
    }
    if (chosen == null) {
      for (final n in nodes.reversed) {
        if (caret >= n.end &&
            text
                .substring(n.end, caret.clamp(n.end, parent.end))
                .trim()
                .isEmpty) {
          chosen = n;
          break;
        }
      }
    }
    // A comma and the whitespace after it belong to the following tag.
    if (chosen == null) {
      for (final n in nodes) {
        if (caret < n.start &&
            RegExp(r'^[\s,，]*$').hasMatch(text.substring(caret, n.start))) {
          chosen = n;
          break;
        }
      }
    }
    chosen ??= caret <= nodes.first.start
        ? nodes.first
        : caret >= nodes.last.end
            ? nodes.last
            : null;
    if (chosen == null) return null;
    return chosen.kind == _Kind.tag ? chosen : locate(chosen, caret);
  }
}
