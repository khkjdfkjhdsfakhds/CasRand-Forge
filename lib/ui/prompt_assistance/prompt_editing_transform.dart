import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter/services.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_weight_syntax.dart';

enum PromptEditingScope { fixedPrompt, cascadedEntry }

enum PromptWeightDirection { increase, decrease }

enum PromptMoveDirection { backward, forward }

class PromptTextEditResult {
  final TextEditingValue value;
  final bool changed;
  final bool unsafeSelection;
  const PromptTextEditResult({
    required this.value,
    required this.changed,
    this.unsafeSelection = false,
  });
  static PromptTextEditResult unchanged(TextEditingValue value) =>
      PromptTextEditResult(value: value, changed: false);
  static PromptTextEditResult blocked(TextEditingValue value) =>
      PromptTextEditResult(value: value, changed: false, unsafeSelection: true);
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
    if (value.selection.isValid && !value.selection.isCollapsed) {
      return _adjustSelection(value, direction, scope, editableRange);
    }
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
      final prefix = '${_number(next)}::';
      final suffix = value.text.substring(group.bodyEnd, group.end);
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
    if (value.selection.isValid && !value.selection.isCollapsed) {
      return _moveSelection(value, direction, scope, editableRange);
    }
    final target = _target(value, scope, editableRange);
    if (target == null) return PromptTextEditResult.unchanged(value);
    final (leaf, caret) = target;
    return _moveNode(value, leaf, caret, direction);
  }

  static PromptTextEditResult _moveNode(TextEditingValue value, _Node leaf,
      int caret, PromptMoveDirection direction,
      {bool enterWeight = true, bool selectedBlock = false}) {
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
      if (enterWeight &&
          !originallyWrapped &&
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
        final replacement = selectedBlock && close == '::'
            ? _appendWeightClose('$prefix$inside')
            : '$prefix$inside$close';
        return _replace(
            value, left.start, right.end, replacement, left.start + caretIn);
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

  /// Explicit selections are source ranges, never midpoint targets. Only
  /// descend through a wrapper when both endpoints are inside its body.
  /// Crossing half a wrapper or a candidate boundary is an atomic no-op.
  static _SelectedRange? _selectedRange(
      TextEditingValue value, PromptEditingScope scope, TextRange? range) {
    final text = value.text;
    if (value.selection.end > text.length) return null;
    var start = value.selection.start;
    var end = value.selection.end;
    final lower = range?.start ?? 0;
    final upper = range?.end ?? text.length;
    if (start < lower || end > upper || lower < 0 || upper > text.length) {
      return null;
    }
    // Do not split an emoji, combining sequence or surrogate pair.
    var offset = 0;
    var startAligned = start == 0;
    var endAligned = false;
    for (final character in text.characters) {
      offset += character.length;
      if (offset == start) startAligned = true;
      if (offset >= end) {
        endAligned = offset == end;
        break;
      }
    }
    if (!startAligned || !endAligned) return null;
    while (start < end && text[start].trim().isEmpty) {
      start++;
    }
    while (end > start && text[end - 1].trim().isEmpty) {
      end--;
    }
    if (start == end) return null;
    final parser =
        _Parser(text, upper, scope == PromptEditingScope.fixedPrompt);
    final root = _Node(_Kind.root, lower, upper, lower, upper);
    parser.sequence(root, lower, null, 0);
    if (parser.comments.any((c) => start < c.end && end > c.start) ||
        text.substring(start, end).contains('|')) {
      return null;
    }
    _SelectedRange? locate(_Node parent) {
      final nodes =
          parent.children.where((n) => n.start < end && n.end > start).toList();
      if (nodes.isEmpty) return null;
      for (var i = 1; i < nodes.length; i++) {
        if (!RegExp(r'^[\s,，]*$')
            .hasMatch(text.substring(nodes[i - 1].end, nodes[i].start))) {
          return null;
        }
      }
      for (final n in nodes) {
        if (n.kind != _Kind.tag) {
          if (n.end == n.bodyEnd) return null;
          if (start >= n.bodyStart && end <= n.bodyEnd) return locate(n);
          if (start > n.start || end < n.end) return null;
        } else if (text.substring(n.start, n.end).contains(RegExp(r'[()]')) &&
            (start > n.start || end < n.end)) {
          return null;
        }
      }
      var parentheses = 0;
      for (final unit in text.substring(start, end).codeUnits) {
        if (unit == 40) parentheses++;
        if (unit == 41 && --parentheses < 0) return null;
      }
      if (parentheses != 0) return null;
      // Delimiters at the outer edges are not movable text. Interior commas
      // stay in the block; surrounding spacing stays in its original gap.
      if (start < nodes.first.start || end > nodes.last.end) return null;
      return _SelectedRange(parent, nodes, start, end);
    }

    return locate(root);
  }

  static bool _composing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  static PromptTextEditResult _adjustSelection(
      TextEditingValue value,
      PromptWeightDirection direction,
      PromptEditingScope scope,
      TextRange? range) {
    if (_composing(value)) return PromptTextEditResult.unchanged(value);
    final selected = _selectedRange(value, scope, range);
    if (selected == null) return PromptTextEditResult.blocked(value);
    final delta =
        direction == PromptWeightDirection.increase ? weightStep : -weightStep;
    final parent = selected.parent;
    final text = value.text;
    if (parent.kind == _Kind.weight) {
      // Numeric nesting does not restore the enclosing active weight after a
      // close. Split flat groups explicitly, and decline ambiguous nesting.
      if (parent.children.any((n) => n.kind != _Kind.tag) ||
          text.substring(parent.bodyStart, parent.bodyEnd).contains('\n') ||
          _hasWeightAncestor(parent)) {
        return PromptTextEditResult.blocked(value);
      }
      final old = _weightOf(text, parent);
      final next = _nextWeight(old, delta);
      if (next == old) return PromptTextEditResult.unchanged(value);
      final before = text.substring(parent.bodyStart, selected.start);
      final body = text.substring(selected.start, selected.end);
      final after = text.substring(selected.end, parent.bodyEnd);
      if (before.trim().isEmpty && after.trim().isEmpty) {
        final prefix = '${_number(next)}::';
        final suffix = text.substring(parent.bodyEnd, parent.end);
        return _replaceSelected(
            value,
            parent.start,
            parent.end,
            '$prefix$before$body$after$suffix',
            prefix.length + before.length,
            prefix.length + before.length + body.length);
      }
      final left = _weightedRun(before, old);
      final middle =
          _weightedRun(body + (after.trim().isEmpty ? after : ''), next);
      final right = _weightedRun(after.trim().isEmpty ? '' : after, old);
      final joinLeft = _weightJoiner(left.text, middle.text);
      final joinRight = _weightJoiner(middle.text, right.text);
      final replacement =
          '${left.text}$joinLeft${middle.text}$joinRight${right.text}';
      return _replaceSelected(
          value,
          parent.start,
          parent.end,
          replacement,
          left.text.length + joinLeft.length + middle.start,
          left.text.length + joinLeft.length + middle.end);
    }
    if (_hasWeightAncestor(parent)) {
      return PromptTextEditResult.blocked(value);
    }
    final rendered =
        _weightSequence(text, parent, selected.start, selected.end, delta);
    if (rendered == null) return PromptTextEditResult.blocked(value);
    return _replaceSelected(value, selected.start, selected.end, rendered.text,
        rendered.start, rendered.end);
  }

  static bool _hasWeightAncestor(_Node node) {
    for (var p = node.parent; p != null; p = p.parent) {
      if (p.kind == _Kind.weight) return true;
    }
    return false;
  }

  static double _weightOf(String text, _Node node) =>
      double.parse(text.substring(node.start, node.bodyStart - 2));
  static double _nextWeight(double old, double delta) =>
      ((old + delta).clamp(minimumWeight, maximumWeight) * 10).round() / 10;

  static _SelectedText _weightedRun(String body, double weight) {
    final leading = body.length - body.trimLeft().length;
    final trailing = body.length - body.trimRight().length;
    if (RegExp(r'^[\s,，]*$').hasMatch(body)) {
      return _SelectedText(body, 0, body.length);
    }
    final content = body.substring(leading, body.length - trailing);
    final prefix = '${body.substring(0, leading)}${_number(weight)}::';
    final text = _appendWeightClose(
        '$prefix$content${body.substring(body.length - trailing)}');
    return _SelectedText(text, prefix.length, prefix.length + content.length);
  }

  // A neutral fragment may end immediately before a newly inserted opener.
  // Give that opener a lexical boundary without normalizing unrelated text.
  static String _weightJoiner(String left, String right) => left.isNotEmpty &&
          right.isNotEmpty &&
          RegExp(r'[\p{L}\p{N}_.]$', unicode: true).hasMatch(left) &&
          PromptWeightSyntax.numericOpenerAt(right, 0) != null
      ? ' '
      : '';

  static _SelectedText? _weightSequence(
      String text, _Node parent, int start, int end, double delta) {
    final pieces = <_SelectedText>[];
    var safe = true;
    var cursor = start;
    void plain(int stop) {
      if (stop <= cursor) return;
      if (text.substring(cursor, stop).contains('::')) {
        safe = false;
        return;
      }
      // A fixed prompt line resets numeric weight; do not wrap across it.
      final lines = text.substring(cursor, stop).split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) pieces.add(const _SelectedText('\n', 0, 1));
        if (lines[i].isNotEmpty) {
          pieces.add(_weightedRun(lines[i], 1 + delta));
        }
      }
    }

    for (final n in parent.children) {
      if (n.kind == _Kind.tag || n.end <= start || n.start >= end) continue;
      if (n.start < start || n.end > end || n.end == n.bodyEnd) return null;
      plain(n.start);
      if (n.kind == _Kind.weight) {
        if (n.children.any((c) => c.kind != _Kind.tag) ||
            text.substring(n.bodyStart, n.bodyEnd).contains('\n')) {
          return null;
        }
        final old = _weightOf(text, n);
        final next = _nextWeight(old, delta);
        pieces.add(next == old
            ? _SelectedText(text.substring(n.start, n.end),
                n.bodyStart - n.start, n.bodyEnd - n.start)
            : _weightedRun(text.substring(n.bodyStart, n.bodyEnd), next));
      } else if (n.kind == _Kind.brace) {
        final body = _weightSequence(text, n, n.bodyStart, n.bodyEnd, delta);
        if (body == null) return null;
        final wrapped = text.substring(n.start, n.bodyStart) +
            body.text +
            text.substring(n.bodyEnd, n.end);
        pieces.add(_SelectedText(wrapped, 0, wrapped.length));
      } else {
        return null;
      }
      cursor = n.end;
    }
    plain(end);
    if (!safe) return null;
    if (pieces.isEmpty) return null;
    if (pieces.length == 1) return pieces.single;
    final output = StringBuffer();
    var previous = '';
    for (final piece in pieces) {
      output.write(_weightJoiner(previous, piece.text));
      output.write(piece.text);
      if (piece.text.isNotEmpty) previous = piece.text;
    }
    final rendered = output.toString();
    // Include complete inner wrappers for repeat presses on a mixed block.
    return _SelectedText(rendered, 0, rendered.length);
  }

  static PromptTextEditResult _moveSelection(
      TextEditingValue value,
      PromptMoveDirection direction,
      PromptEditingScope scope,
      TextRange? range) {
    if (_composing(value)) return PromptTextEditResult.unchanged(value);
    final selected = _selectedRange(value, scope, range);
    if (selected == null) return PromptTextEditResult.blocked(value);
    final parent = selected.parent;
    final nodes = selected.nodes;
    final text = value.text;
    if (_hasWeightAncestor(parent) ||
        (parent.kind == _Kind.weight &&
            parent.children.any((n) => n.kind != _Kind.tag))) {
      return PromptTextEditResult.blocked(value);
    }
    // Split tag fragments into siblings, then move the selected block with
    // exactly the same structural rules as a caret-targeted item.
    final block = _Node(
        _Kind.tag, selected.start, selected.end, selected.start, selected.end);
    final replacements = <_Node>[];
    void fragment(int start, int end) {
      while (start < end && text[start].trim().isEmpty) {
        start++;
      }
      while (end > start && text[end - 1].trim().isEmpty) {
        end--;
      }
      if (start < end) {
        replacements.add(_Node(_Kind.tag, start, end, start, end));
      }
    }

    fragment(nodes.first.start, selected.start);
    replacements.add(block);
    fragment(selected.end, nodes.last.end);
    final first = parent.children.indexOf(nodes.first);
    parent.children.replaceRange(first, first + nodes.length, replacements);
    for (final n in replacements) {
      n.parent = parent;
    }
    final result = _moveNode(value, block, selected.start, direction,
        enterWeight: nodes.every((n) => n.kind == _Kind.tag),
        selectedBlock: true);
    if (!result.changed) return result;
    final start = result.value.selection.extentOffset;
    return PromptTextEditResult(
      value: result.value.copyWith(
          selection: _selectionAt(
              value.selection, start, start + selected.end - selected.start)),
      changed: true,
    );
  }

  static TextSelection _selectionAt(
          TextSelection original, int start, int end) =>
      TextSelection(
        baseOffset: original.baseOffset <= original.extentOffset ? start : end,
        extentOffset:
            original.baseOffset <= original.extentOffset ? end : start,
        affinity: original.affinity,
        isDirectional: original.isDirectional,
      );

  static PromptTextEditResult _replaceSelected(TextEditingValue value,
      int start, int end, String text, int selectionStart, int selectionEnd) {
    final leftJoin = _weightJoiner(value.text.substring(0, start), text);
    final rightJoin = _weightJoiner(text, value.text.substring(end));
    final replacement =
        value.text.replaceRange(start, end, '$leftJoin$text$rightJoin');
    if (replacement == value.text) return PromptTextEditResult.unchanged(value);
    return PromptTextEditResult(
      value: value.copyWith(
        text: replacement,
        selection: _selectionAt(
            value.selection,
            start + leftJoin.length + selectionStart,
            start + leftJoin.length + selectionEnd),
        composing: TextRange.empty,
      ),
      changed: true,
    );
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

class _SelectedRange {
  final _Node parent;
  final List<_Node> nodes;
  final int start;
  final int end;
  const _SelectedRange(this.parent, this.nodes, this.start, this.end);
}

class _SelectedText {
  final String text;
  final int start;
  final int end;
  const _SelectedText(this.text, this.start, this.end);
}

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
