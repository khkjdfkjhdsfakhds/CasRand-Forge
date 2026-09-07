import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_transform.dart';

TextEditingValue at(String text, int offset, {TextRange? composing}) {
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: offset),
    composing: composing ?? TextRange.empty,
  );
}

PromptTextEditResult weight(
  String text,
  int offset,
  PromptWeightDirection direction, {
  PromptEditingScope scope = PromptEditingScope.fixedPrompt,
  TextRange? editableRange,
  TextRange? composing,
}) {
  return PromptEditingTransform.adjustWeight(
    at(text, offset, composing: composing),
    direction: direction,
    scope: scope,
    editableRange: editableRange,
  );
}

PromptTextEditResult move(
  String text,
  int offset,
  PromptMoveDirection direction, {
  PromptEditingScope scope = PromptEditingScope.fixedPrompt,
  TextRange? editableRange,
}) {
  return PromptEditingTransform.move(
    at(text, offset),
    direction: direction,
    scope: scope,
    editableRange: editableRange,
  );
}

void main() {
  group('weight transforms', () {
    test('wraps an unweighted tag and keeps caret attached to its body', () {
      final result = weight('blue eyes', 9, PromptWeightDirection.increase);

      expect(result.changed, isTrue);
      expect(result.value.text, '1.1::blue eyes::');
      expect(result.value.selection.extentOffset, '1.1::blue eyes'.length);

      final repeated = PromptEditingTransform.adjustWeight(
        result.value,
        direction: PromptWeightDirection.increase,
      );
      expect(repeated.value.text, '1.2::blue eyes::');
      expect(repeated.value.selection.extentOffset, '1.2::blue eyes'.length);
    });

    test('decrements an unweighted tag to the numeric syntax', () {
      final result = weight('tag', 3, PromptWeightDirection.decrease);
      expect(result.value.text, '0.9::tag::');
      expect(result.value.selection.extentOffset, '0.9::tag'.length);
    });

    test('adds the safe separator when a newly weighted tag ends in a digit',
        () {
      final result = weight('haku89', 6, PromptWeightDirection.increase);

      expect(result.value.text, '1.1::haku89 ::');
      expect(result.value.selection.extentOffset, '1.1::haku89'.length);
    });

    test('rounds numeric weights and unwraps exactly at one', () {
      final up = weight('0.9::tag::', 9, PromptWeightDirection.increase);
      expect(up.value.text, 'tag');
      // 1 is represented by the original unweighted body, not a redundant
      // numeric wrapper.
      final down = weight('1.00::tag::', 11, PromptWeightDirection.decrease);
      expect(down.value.text, '0.9::tag::');
      final unwrapped = weight('0.9::tag::', 9, PromptWeightDirection.increase);
      expect(unwrapped.value.text, 'tag');
      final toOne = weight('1.00::tag::', 11, PromptWeightDirection.increase);
      expect(toOne.value.text, '1.1::tag::');
    });

    test('clamps at the documented numeric boundaries', () {
      final high = weight('10::tag::', 9, PromptWeightDirection.increase);
      expect(high.value.text, '10::tag::');
      expect(high.changed, isFalse);
      final low = weight('-10::tag::', 10, PromptWeightDirection.decrease);
      expect(low.value.text, '-10::tag::');
      expect(low.changed, isFalse);
    });

    test('preserves brace and bracket syntax, including mixed nesting', () {
      expect(
        weight('{tag}', 4, PromptWeightDirection.increase).value.text,
        '{{tag}}',
      );
      expect(
        weight('{{tag}}', 5, PromptWeightDirection.decrease).value.text,
        '{tag}',
      );
      expect(
        weight('[tag]', 4, PromptWeightDirection.increase).value.text,
        'tag',
      );
      expect(
        weight('tag', 3, PromptWeightDirection.decrease).value.text,
        '0.9::tag::',
      );
      expect(
        weight('{[tag]}', 6, PromptWeightDirection.increase).value.text,
        '{{[tag]}}',
      );
      expect(
        weight('{[tag]}', 6, PromptWeightDirection.decrease).value.text,
        '[tag]',
      );
      expect(
        weight('[{tag}]', 6, PromptWeightDirection.increase).value.text,
        '{tag}',
      );
    });

    test('leaves malformed, comment and composing edits unchanged', () {
      final malformed = weight('{tag', 4, PromptWeightDirection.increase);
      expect(malformed.changed, isFalse);
      expect(malformed.value.text, '{tag');
      final comment = weight('# tag', 5, PromptWeightDirection.increase);
      expect(comment.changed, isFalse);
      final composing = weight(
        'tag',
        3,
        PromptWeightDirection.increase,
        composing: const TextRange(start: 0, end: 3),
      );
      expect(composing.changed, isFalse);
      final selection = PromptEditingTransform.adjustWeight(
        const TextEditingValue(
          text: 'tag',
          selection: TextSelection(baseOffset: 0, extentOffset: 3),
        ),
        direction: PromptWeightDirection.increase,
      );
      expect(selection.changed, isFalse);
    });

    test('adjusts weight when tags are separated by Chinese comma', () {
      final firstTag =
          weight('blue eyes，red hair', 4, PromptWeightDirection.increase);
      expect(firstTag.changed, isTrue);
      expect(firstTag.value.text, '1.1::blue eyes::，red hair');

      final secondTag =
          weight('blue eyes，red hair', 14, PromptWeightDirection.increase);
      expect(secondTag.changed, isTrue);
      expect(secondTag.value.text, 'blue eyes，1.1::red hair::');
    });
  });

  group('position transforms', () {
    test('swaps one item while preserving separators and follows the caret',
        () {
      const text = 'one,  two\nthree';
      final right = move(text, 8, PromptMoveDirection.forward);
      expect(right.value.text, 'one,  three\ntwo');
      expect(right.value.selection.extentOffset, 'one,  three\n'.length + 2);

      final left = move(
        right.value.text,
        right.value.selection.extentOffset,
        PromptMoveDirection.backward,
      );
      expect(left.value.text, text);
      expect(left.value.selection.extentOffset, 'one,  two'.length - 1);
    });

    test('keeps the caret relative to a longer item moved over a shorter one',
        () {
      const text = 'long, a';
      final right = move(text, 2, PromptMoveDirection.forward);
      expect(right.value.text, 'a, long');
      // The caret was two code units into `long`; it remains two code units
      // into the moved `long`, rather than being clamped to `a`'s length.
      expect(right.value.selection.extentOffset, 5);

      final left = move(
        right.value.text,
        right.value.selection.extentOffset,
        PromptMoveDirection.backward,
      );
      expect(left.value.text, text);
      expect(left.value.selection.extentOffset, 2);
    });

    test('keeps grouped commas together as one item', () {
      final result = move(
        '(one, two), three',
        2,
        PromptMoveDirection.forward,
      );
      expect(result.value.text, 'three, (one, two)');
    });

    test('does not move at first or last boundary', () {
      final first = move('one, two', 1, PromptMoveDirection.backward);
      expect(first.changed, isFalse);
      final last = move('one, two', 8, PromptMoveDirection.forward);
      expect(last.changed, isFalse);
    });

    test('swaps items separated by Chinese comma', () {
      const text = 'one，two';
      final right = move(text, 1, PromptMoveDirection.forward);
      expect(right.value.text, 'two，one');
    });

    test('does not target comments and keeps them byte-for-byte', () {
      final comment = move('# note\none, two', 3, PromptMoveDirection.forward);
      expect(comment.changed, isFalse);
      final target = move('# note\none, two', 8, PromptMoveDirection.forward);
      expect(target.value.text, '# note\ntwo, one');
    });

    test('cascaded scope keeps internal newlines in the current entry', () {
      const text = 'one\nline, two';
      final result = move(
        text,
        1,
        PromptMoveDirection.forward,
        scope: PromptEditingScope.cascadedEntry,
        editableRange: const TextRange(start: 0, end: 13),
      );
      expect(result.value.text, 'two, one\nline');
      expect(result.changed, isTrue);
      final commaMove = move(
        text,
        11,
        PromptMoveDirection.backward,
        scope: PromptEditingScope.cascadedEntry,
        editableRange: const TextRange(start: 0, end: 13),
      );
      expect(commaMove.value.text, 'two, one\nline');
    });

    test('confines cascaded movement to the supplied entry range', () {
      const text = 'one, two\nthree, four';
      final secondEntryStart = text.indexOf('three');
      final result = move(
        text,
        secondEntryStart + 1,
        PromptMoveDirection.backward,
        scope: PromptEditingScope.cascadedEntry,
        editableRange: TextRange(start: secondEntryStart, end: text.length),
      );
      expect(result.value.text, text);
      expect(result.changed, isFalse);
    });

    test('does not absorb internal comment lines into an editable item', () {
      const text = 'one\n# note\ntwo, three';
      final result = move(
        text,
        text.lastIndexOf('three') + 2,
        PromptMoveDirection.backward,
        scope: PromptEditingScope.cascadedEntry,
        editableRange: const TextRange(start: 0, end: 21),
      );
      expect(result.value.text, 'one\n# note\nthree, two');
    });
  });
}
