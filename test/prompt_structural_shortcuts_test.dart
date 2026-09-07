import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_editing_transform.dart';

TextEditingValue cursor(String text, String target, {int inset = 1}) =>
    TextEditingValue(
        text: text,
        selection:
            TextSelection.collapsed(offset: text.indexOf(target) + inset));
PromptTextEditResult up(TextEditingValue value) =>
    PromptEditingTransform.adjustWeight(value,
        direction: PromptWeightDirection.increase);
PromptTextEditResult shift(TextEditingValue value, bool right) =>
    PromptEditingTransform.move(value,
        direction:
            right ? PromptMoveDirection.forward : PromptMoveDirection.backward);

void main() {
  test('adjacent numeric groups need no comma and target second only', () {
    const text = '1.2::blue eyes:: 0.8::red hair::';
    final value = cursor(text, 'red hair');
    expect(up(value).value.text, '1.2::blue eyes:: 0.9::red hair::');
    final moved = shift(value, false);
    expect(moved.value.text, '0.8::red hair:: 1.2::blue eyes::');
    expect(up(moved.value).value.text, '0.9::red hair:: 1.2::blue eyes::');
  });
  test('text after a closed weight is independent without a comma', () {
    const text = '1.2::blue eyes:: red hair';
    expect(
        up(cursor(text, 'red')).value.text, '1.2::blue eyes:: 1.1::red hair::');
    expect(shift(cursor(text, 'red'), false).value.text,
        '1.2::blue eyes, red hair::');
  });
  test('open weights adjust and moving them before a sibling closes scope', () {
    expect(up(cursor('1.2::blue eyes', 'blue')).value.text, '1.3::blue eyes');
    final moved = shift(cursor('red, 1.2::blue eyes', 'blue'), false);
    expect(moved.value.text, '1.2::blue eyes::, red');
    expect(up(cursor(moved.value.text, 'red')).value.text,
        '1.2::blue eyes::, 1.1::red::');
  });
  test('open group last child exits without carrying numeric scope', () {
    final moved = shift(cursor('1.2::one, two', 'two'), true);
    expect(moved.value.text, '1.2::one::, two');
    expect(up(moved.value).value.text, '1.2::one::, 1.1::two::');
  });
  test('weight reset does not restore an earlier numeric weight', () {
    const text = '1.2::one, 0.8::two::, three::';
    expect(up(cursor(text, 'two')).value.text, '1.2::one, 0.9::two::, three::');
    expect(up(cursor(text, 'three')).value.text,
        '1.2::one, 0.8::two::, 1.1::three::::');
  });
  test('forward and reversed selections use the same midpoint target', () {
    const text = 'blue eyes red hair, green eyes';
    for (final selection in const [
      TextSelection(baseOffset: 0, extentOffset: 9),
      TextSelection(baseOffset: 9, extentOffset: 0),
    ]) {
      expect(up(TextEditingValue(text: text, selection: selection)).value.text,
          '1.1::blue eyes red hair::, green eyes');
    }
  });
  test('prefix, closer and trailing space have a stable weighted target', () {
    const text = '1.2::blue eyes::   0.8::red hair::';
    for (final offset in [0, 3, 5, 14, 15, 16, 17]) {
      expect(
          up(TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: offset)))
              .value
              .text,
          '1.3::blue eyes::   0.8::red hair::',
          reason: 'offset $offset');
    }
    expect(up(cursor(text, '0.8', inset: 0)).value.text,
        '1.2::blue eyes::   0.9::red hair::');
  });
  test('whitespace before a comma attaches left and after it attaches right',
      () {
    const text = 'one  ,  two';
    for (final offset in [3, 4, 5]) {
      expect(
          up(TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: offset)))
              .value
              .text,
          '1.1::one::  ,  two');
    }
    for (final offset in [6, 7, 8]) {
      expect(
          up(TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: offset)))
              .value
              .text,
          'one  ,  1.1::two::');
    }
  });
  test('sibling swaps preserve local whitespace then group edges move out', () {
    const text = 'before，1.2::one,  two, three::，after';
    final swapped = shift(cursor(text, 'two'), false);
    expect(swapped.value.text, 'before，1.2::two,  one, three::，after');
    final exited = shift(swapped.value, false);
    expect(exited.value.text, 'before，two,  1.2::one, three::，after');
    expect(up(exited.value).value.text,
        'before，1.1::two::,  1.2::one, three::，after');
  });
  test('unweighted neighbours enter either edge of numeric groups', () {
    expect(shift(cursor('one, 1.2::two, three::', 'one'), true).value.text,
        '1.2::one, two, three::');
    expect(shift(cursor('1.2::one, two::, three', 'three'), false).value.text,
        '1.2::one, two, three::');
  });
  test('one-child brace and weight wrappers travel with their tag', () {
    expect(shift(cursor('{one}, two', 'one'), true).value.text, 'two, {one}');
    expect(shift(cursor('1.2::one::, two', 'one'), true).value.text,
        'two, 1.2::one::');
    expect(shift(cursor('[one, two]', 'one'), false).value.text, 'one, [two]');
  });
  test('random alternatives remain separate and their braces survive edits',
      () {
    const text = '||{one}|[two]||, three';
    expect(up(cursor(text, 'two')).value.text, '||{one}|[1.1::two::]||, three');
    expect(shift(cursor(text, 'two'), false).value, cursor(text, 'two'));
  });
  test('an exact structural boundary belongs to the next item', () {
    const text = '1.2::one::0.8::two::';
    expect(
        up(cursor(text, '0.8', inset: 0)).value.text, '1.2::one::0.9::two::');
    expect(
        shift(cursor(text, 'two'), false).value.text, '0.8::two:: 1.2::one::');
  });
  test('unicode is retained and plain spaces do not guess tag boundaries', () {
    expect(up(cursor('蓝眼睛 👩🏽‍🎨 red hair', 'red')).value.text,
        '1.1::蓝眼睛 👩🏽‍🎨 red hair::');
  });
  test('fixed newline resets open weight but scoped candidate stays intact',
      () {
    expect(
        up(cursor('1.2::one\ntwo', 'two')).value.text, '1.2::one\n1.1::two::');
    const text = 'before\nline, two\nafter';
    final moved = PromptEditingTransform.move(cursor(text, 'two'),
        direction: PromptMoveDirection.backward,
        scope: PromptEditingScope.cascadedEntry,
        editableRange: const TextRange(start: 7, end: 16));
    expect(moved.value.text, 'before\ntwo, line\nafter');
  });
  test('moving a child preserves wrapper padding and safe numeric endings', () {
    expect(shift(cursor('1.2::  one, two::', 'one'), false).value.text,
        'one, 1.2::  two::');
    expect(shift(cursor('1.2::one9, two  ::', 'two'), true).value.text,
        '1.2::one9  ::, two');
    expect(shift(cursor('one, 1.2::two9', 'two'), false).value.text,
        '1.2::two9 ::, one');
  });
  test('nested weight prefixes target their own number rather than a child',
      () {
    const text = '1.2::0.8::one::::';
    expect(up(cursor(text, '1.2', inset: 0)).value.text, '1.3::0.8::one::::');
    expect(up(cursor(text, '0.8', inset: 0)).value.text, '1.2::0.9::one::::');
  });
}
