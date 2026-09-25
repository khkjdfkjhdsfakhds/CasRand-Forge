import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_transform.dart';

TextEditingValue selected(String text, String body, {bool reverse = false}) {
  final start = text.indexOf(body);
  assert(start >= 0);
  return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: reverse ? start + body.length : start,
        extentOffset: reverse ? start : start + body.length,
      ));
}

PromptTextEditResult weight(TextEditingValue value, {bool up = true}) =>
    PromptEditingTransform.adjustWeight(value,
        direction: up
            ? PromptWeightDirection.increase
            : PromptWeightDirection.decrease);
PromptTextEditResult move(TextEditingValue value, {bool right = true}) =>
    PromptEditingTransform.move(value,
        direction:
            right ? PromptMoveDirection.forward : PromptMoveDirection.backward);
String selectionText(TextEditingValue value) =>
    value.selection.textInside(value.text);

void main() {
  test('multi-tag block survives neutral weight and movement in both scopes',
      () {
    for (final scope in PromptEditingScope.values) {
      for (final reverse in [false, true]) {
        for (final initial in [0.9, 1.1]) {
          var value = selected(
              'before, $initial::one, two::, after', 'one, two',
              reverse: reverse);
          value = PromptEditingTransform.adjustWeight(value,
                  direction: initial < 1
                      ? PromptWeightDirection.increase
                      : PromptWeightDirection.decrease,
                  scope: scope)
              .value;
          expect(value.text, 'before, 1::one, two::, after');
          expect(selectionText(value), 'one, two');
          value = PromptEditingTransform.move(value,
                  direction: PromptMoveDirection.forward, scope: scope)
              .value;
          expect(value.text, 'before, after, 1::one, two::');
          expect(selectionText(value), 'one, two');
          value = PromptEditingTransform.adjustWeight(value,
                  direction: PromptWeightDirection.increase, scope: scope)
              .value;
          expect(value.text, 'before, after, 1.1::one, two::');
          value = PromptEditingTransform.move(value,
                  direction: PromptMoveDirection.backward, scope: scope)
              .value;
          expect(value.text, 'before, 1.1::one, two::, after');
          expect(selectionText(value), 'one, two');
          expect(value.selection.baseOffset > value.selection.extentOffset,
              reverse);
        }
      }
    }
  });
  test('mixed explicit weights retain neutral wrappers on repeat presses', () {
    var value = selected('0.9::one::, 1.1::two::', '0.9::one::, 1.1::two::');
    value = weight(value).value;
    expect(value.text, '1::one::, 1.2::two::');
    value = weight(value, up: false).value;
    expect(value.text, '0.9::one::, 1.1::two::');
  });

  test('flat-group character weights change only within every selected range',
      () {
    // Independent, deliberately small oracle: scan numeric markers and letters
    // rather than reusing the production structural parser or serializer.
    List<(String, double)> letters(String text) {
      var active = 1.0;
      final result = <(String, double)>[];
      final tokens = RegExp(r'([+-]?(?:\d+(?:\.\d*)?|\.\d+))::|::|[a-z]');
      for (final token in tokens.allMatches(text)) {
        if (token.group(1) != null) {
          active = double.parse(token.group(1)!);
        } else if (token.group(0) == '::') {
          active = 1;
        } else {
          result.add((token.group(0)!, active));
        }
      }
      return result;
    }

    for (final old in [-10.0, 0.5, 0.9, 1.0, 1.2, 9.9, 10.0]) {
      const body = 'aa, bb, cc';
      final source = '$old::$body::';
      final offset = source.indexOf(body);
      for (var start = 0; start < body.length; start++) {
        if (!RegExp('[a-z]').hasMatch(body[start])) continue;
        for (var end = start + 1; end <= body.length; end++) {
          if (!RegExp('[a-z]').hasMatch(body[end - 1])) continue;
          for (final up in [true, false]) {
            final value = TextEditingValue(
                text: source,
                selection: TextSelection(
                    baseOffset: offset + start, extentOffset: offset + end));
            final result = weight(value, up: up);
            expect(result.unsafeSelection, isFalse);
            final expected = <(String, double)>[];
            for (var i = 0; i < body.length; i++) {
              if (!RegExp('[a-z]').hasMatch(body[i])) continue;
              final next =
                  ((old + (up ? .1 : -.1)).clamp(-10, 10) * 10).round() / 10;
              expected.add((body[i], i >= start && i < end ? next : old));
            }
            expect(letters(result.value.text), expected,
                reason: '$source [$start,$end] up=$up -> ${result.value.text}');
            expect(selectionText(result.value), body.substring(start, end));
          }
        }
      }
    }
  });

  test('movement never loses selected characters across all corpus ranges', () {
    for (final source in [
      'aa, bb, cc',
      '1.2::aa, bb::, cc',
      '{aa, bb}, cc',
      '1.2::aa:: 0.8::bb::, cc',
      'aa, (bb, cc)',
      '||aa|bb||, cc'
    ]) {
      for (var start = 0; start < source.length; start++) {
        for (var end = start + 1; end <= source.length; end++) {
          final value = TextEditingValue(
              text: source,
              selection: TextSelection(baseOffset: start, extentOffset: end));
          for (final right in [false, true]) {
            final result = move(value, right: right);
            if (!result.changed) {
              expect(result.value, value);
              continue;
            }
            expect(selectionText(result.value),
                source.substring(start, end).trim(),
                reason: '$source [$start,$end] right=$right');
            final before = RegExp('[a-z]')
                .allMatches(source)
                .map((m) => m.group(0)!)
                .toList()
              ..sort();
            final after = RegExp('[a-z]')
                .allMatches(result.value.text)
                .map((m) => m.group(0)!)
                .toList()
              ..sort();
            expect(after, before);
          }
        }
      }
    }
  });

  test('partial tag stays selected and repeats in both directions', () {
    var result =
        weight(selected('blue eyes red hair, green eyes', 'blue eyes'));
    expect(result.value.text, '1.1::blue eyes:: red hair, green eyes');
    expect(selectionText(result.value), 'blue eyes');
    result = weight(result.value);
    expect(result.value.text, '1.2::blue eyes:: red hair, green eyes');
    result = weight(weight(result.value, up: false).value, up: false);
    expect(result.value.text, '1::blue eyes:: red hair, green eyes');
    expect(selectionText(result.value), 'blue eyes');
  });
  test('several selected tags are adjusted as a block', () {
    final result = weight(
        selected('before, blue eyes，red hair, after', 'blue eyes，red hair'));
    expect(result.value.text, 'before, 1.1::blue eyes，red hair::, after');
    expect(selectionText(result.value), 'blue eyes，red hair');
    expect(weight(result.value).value.text,
        'before, 1.2::blue eyes，red hair::, after');
  });
  test('partial existing weight is split without changing the remainder', () {
    var result = weight(selected('1.2::blue eyes, red hair::', 'blue eyes'));
    expect(result.value.text, '1.3::blue eyes::1.2::, red hair::');
    expect(selectionText(result.value), 'blue eyes');
    result = weight(result.value);
    expect(result.value.text, '1.4::blue eyes::1.2::, red hair::');
    final middle = weight(selected('1.2::one, two, three::', 'two'));
    expect(middle.value.text, '1.2::one, ::1.3::two::1.2::, three::');
    expect(selectionText(middle.value), 'two');
  });
  test('neutral segment does not capture the next weight opener', () {
    final result =
        weight(selected('1.1::blue eyes, red hair::', 'blue eyes'), up: false);
    expect(result.value.text, '1::blue eyes::1.1::, red hair::');
    expect(selectionText(result.value), 'blue eyes');
    expect(
        weight(result.value).value.text, '1.1::blue eyes::1.1::, red hair::');
  });
  test('complete weights keep their differences over repeat presses', () {
    var result = weight(selected(
        'before, 1.2::blue eyes:: 0.7::red hair::, after',
        '1.2::blue eyes:: 0.7::red hair::'));
    expect(
        result.value.text, 'before, 1.3::blue eyes:: 0.8::red hair::, after');
    result = weight(result.value);
    expect(
        result.value.text, 'before, 1.4::blue eyes:: 0.9::red hair::, after');
  });
  test('mixed weighted and plain text remains repeatable', () {
    var result = weight(selected('1.2::one::, two', '1.2::one::, two'));
    expect(result.value.text, '1.3::one::1.1::, two::');
    result = weight(result.value);
    expect(result.value.text, '1.4::one::1.2::, two::');
  });
  test('braces remain balanced without nesting numeric wrappers on repeat', () {
    var result = weight(selected('before, {blue eyes}, after', '{blue eyes}'));
    expect(result.value.text, 'before, {1.1::blue eyes::}, after');
    result = weight(result.value);
    expect(result.value.text, 'before, {1.2::blue eyes::}, after');
  });
  test('numeric ending gets a safe close and retains exact selected text', () {
    final result = weight(selected('before, haku89, after', 'haku89'));
    expect(result.value.text, 'before, 1.1::haku89 ::, after');
    expect(selectionText(result.value), 'haku89');
    expect(weight(result.value).value.text, 'before, 1.2::haku89 ::, after');
  });
  test('word fragments get a valid opener without selecting surrounding text',
      () {
    final result = weight(selected('blue eyes', 'ue'));
    expect(result.value.text, 'bl 1.1::ue:: eyes');
    expect(selectionText(result.value), 'ue');
    expect(weight(result.value).value.text, 'bl 1.2::ue:: eyes');
  });
  test('forward and reverse selection orientations survive edits', () {
    for (final reverse in [false, true]) {
      final result =
          weight(selected('one, two, three', 'two', reverse: reverse));
      expect(selectionText(result.value), 'two');
      expect(
          result.value.selection.baseOffset >
              result.value.selection.extentOffset,
          reverse);
      final moved = move(selected('one, two, three', 'two', reverse: reverse));
      expect(moved.value.text, 'one, three, two');
      expect(selectionText(moved.value), 'two');
      expect(
          moved.value.selection.baseOffset > moved.value.selection.extentOffset,
          reverse);
    }
  });
  test('multi-tag block moves as a unit and returns intact', () {
    final original = selected('zero, one, two，three, four', 'one, two');
    final right = move(original);
    expect(right.value.text, 'zero, three，one, two, four');
    expect(selectionText(right.value), 'one, two');
    expect(move(right.value, right: false).value, original);
  });
  test('fragment swaps with adjacent remaining fragment', () {
    final result = move(selected('blue eyes, red hair', 'blue'));
    expect(result.value.text, 'eyes blue, red hair');
    expect(selectionText(result.value), 'blue');
    expect(move(result.value, right: false).value.text, 'blue eyes, red hair');
  });
  test('whole selected weight groups swap without merging weights', () {
    final result = move(selected('1.2::one::, 0.8::two::', '1.2::one::'));
    expect(result.value.text, '0.8::two::, 1.2::one::');
    expect(selectionText(result.value), '1.2::one::');
  });
  test('selected block follows existing weight-entry and exit rules', () {
    final entered = move(selected('one, two, 1.2::three, four::', 'one, two'));
    expect(entered.value.text, '1.2::one, two, three, four::');
    expect(selectionText(entered.value), 'one, two');
    final exited = move(entered.value, right: false);
    expect(exited.value.text, 'one, two, 1.2::three, four::');
    expect(selectionText(exited.value), 'one, two');
  });
  test('wrapper travels with its fully selected body', () {
    final result = move(selected('1.2::one::, two', 'one'));
    expect(result.value.text, 'two, 1.2::one::');
    expect(selectionText(result.value), 'one');
  });
  test('digit-ending selection enters a weight with a safe closing marker', () {
    final result =
        move(selected('1.2::one, two::, haku89', 'haku89'), right: false);
    expect(result.value.text, '1.2::one, two, haku89 ::');
    expect(selectionText(result.value), 'haku89');
    expect(weight(result.value).value.text, '1.2::one, two, ::1.3::haku89 ::');
  });
  test('boundaries are no-ops preserving selections exactly', () {
    final value = selected('one, two', 'one');
    expect(move(value, right: false).value, value);
    final maximum = selected('10::one::', 'one');
    expect(weight(maximum).value, maximum);
    final fullMaximum = selected('10.0::one::', '10.0::one::');
    expect(weight(fullMaximum).value, fullMaximum);
  });
  test('syntax cuts, random branches and comments are rejected atomically', () {
    for (final pair in [
      ('1.2::blue eyes::, red hair', 'eyes::, red'),
      ('1.2::blue eyes::', '2::blue'),
      ('{one, two}', '{one'),
      ('{one, two', 'one'),
      ('||one|two||', 'one|two'),
      ('one\n# comment\ntwo', 'one\n# comment\ntwo'),
      ('(one, two), three', 'one'),
    ]) {
      final value = selected(pair.$1, pair.$2);
      for (final result in [weight(value), move(value)]) {
        expect(result.value, value, reason: pair.toString());
        expect(result.unsafeSelection, isTrue, reason: pair.toString());
      }
    }
  });
  test('ambiguous nested numeric selections are left intact', () {
    final value = selected('1.2::one, 0.8::two::, three::', 'two');
    expect(weight(value).value, value);
    expect(weight(value).unsafeSelection, isTrue);
  });
  test('both endpoints must be within the same editable entry', () {
    final value = selected('one, two\nthree, four', 'two\nthree');
    final result = PromptEditingTransform.adjustWeight(value,
        direction: PromptWeightDirection.increase,
        scope: PromptEditingScope.cascadedEntry,
        editableRange: const TextRange(start: 0, end: 8));
    expect(result.value, value);
    expect(result.unsafeSelection, isTrue);
    final moved = PromptEditingTransform.move(value,
        direction: PromptMoveDirection.forward,
        scope: PromptEditingScope.cascadedEntry,
        editableRange: const TextRange(start: 9, end: 19));
    expect(moved.value, value);
    expect(moved.unsafeSelection, isTrue);
  });
  test('unicode graphemes survive and partial graphemes are rejected', () {
    final value = selected('蓝眼睛 👩🏽‍🎨, red hair', '👩🏽‍🎨');
    expect(selectionText(weight(value).value), '👩🏽‍🎨');
    final broken = value.copyWith(
        selection: const TextSelection(baseOffset: 4, extentOffset: 6));
    expect(weight(broken).unsafeSelection, isTrue);
    expect(move(broken).value, broken);
  });
  test('IME takes precedence without an unsafe-selection hint', () {
    final value = selected('one, two', 'two')
        .copyWith(composing: const TextRange(start: 5, end: 8));
    for (final result in [weight(value), move(value)]) {
      expect(result.value, value);
      expect(result.unsafeSelection, isFalse);
    }
  });
  test('fixed multiline selection weights each line separately on repeat', () {
    var result = weight(selected('one\ntwo', 'one\ntwo'));
    expect(result.value.text, '1.1::one::\n1.1::two::');
    result = weight(result.value);
    expect(result.value.text, '1.2::one::\n1.2::two::');
  });
}
