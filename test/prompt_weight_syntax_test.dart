import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_weight_syntax.dart';

void main() {
  group('PromptWeightSyntax normalization', () {
    test('makes a digit-ending weighted tag safe and keeps the caret attached',
        () {
      const source = '1.2::haku89::';
      final result = PromptWeightSyntax.normalizeAll(
        const TextEditingValue(
          text: source,
          selection: TextSelection.collapsed(offset: source.length),
        ),
      );

      expect(result.text, '1.2::haku89 ::');
      expect(result.selection, const TextSelection.collapsed(offset: 14));
    });

    test('preserves an independent nested numeric opener', () {
      const source = '1.2::outer, 0.7::inner::, outer::';
      final result = PromptWeightSyntax.normalizeAll(
        const TextEditingValue(
          text: source,
          selection: TextSelection.collapsed(offset: source.length),
        ),
      );

      expect(result.text, source);
    });

    test('does not migrate an untouched legacy ambiguity during another edit',
        () {
      const oldText = '1.2::legacy2::, ta';
      const newText = '1.2::legacy2::, tag';

      final result = PromptWeightSyntax.normalizeEdit(
        const TextEditingValue(
          text: oldText,
          selection: TextSelection.collapsed(offset: oldText.length),
        ),
        const TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newText.length),
        ),
      );

      expect(result.text, newText);
    });

    test('leaves comment lines unchanged', () {
      const source = '# note 1.2::haku89::\n1.2::model2::';
      final result = PromptWeightSyntax.normalizeAll(
        const TextEditingValue(text: source),
      );

      expect(result.text, '# note 1.2::haku89::\n1.2::model2 ::');
    });

    test('normalizes touched edits but preserves safe and nested syntax', () {
      const oldText = '1.2::haku89:';
      const newText = '1.2::haku89::';
      final edited = PromptWeightSyntax.normalizeEdit(
        const TextEditingValue(text: oldText),
        const TextEditingValue(text: newText),
      );

      expect(edited.text, '1.2::haku89 ::');
      expect(
        PromptWeightSyntax.normalizeText(
          '1.2::haku89 ::, 0.7::inner::, outer::',
        ),
        '1.2::haku89 ::, 0.7::inner::, outer::',
      );
      expect(
        PromptWeightSyntax.normalizeText('1.2::2024::'),
        '1.2::2024 ::',
      );
      expect(
        PromptWeightSyntax.normalizeText('1.2::{tag2}::'),
        '1.2::{tag2}::',
      );
    });

    test('does not normalize uncommitted composing text', () {
      const source = '1.2::haku89::';
      const value = TextEditingValue(
        text: source,
        composing: TextRange(start: 5, end: 11),
      );

      expect(PromptWeightSyntax.normalizeAll(value), value);
    });

    test('normalizes the composing range when IME commits unchanged text', () {
      const source = '1.2::haku89::';
      final result = PromptWeightSyntax.normalizeEdit(
        const TextEditingValue(
          text: source,
          composing: TextRange(start: 5, end: 11),
        ),
        const TextEditingValue(
          text: source,
          selection: TextSelection.collapsed(offset: source.length),
        ),
      );

      expect(result.text, '1.2::haku89 ::');
    });

    test('normalizes every ambiguous occurrence and leaves incomplete syntax',
        () {
      expect(
        PromptWeightSyntax.normalizeText('1.2::a2::, 0.8::b3::'),
        '1.2::a2 ::, 0.8::b3 ::',
      );
      expect(PromptWeightSyntax.normalizeText('1.2::unfinished'),
          '1.2::unfinished');
    });

    test('does not carry an unfinished weight into the next physical line', () {
      const source = '1.2::unfinished\nmodel2::';

      expect(PromptWeightSyntax.normalizeText(source), source);
    });
  });

  group('PromptWeightSyntax analysis', () {
    test('reports fixed semantic ranges for increased decreased and neutral',
        () {
      const source = '1.2::haku89 ::, 0.7::blue::, 1::plain ::';

      final spans = PromptWeightSyntax.analyze(source).spans;

      expect(
        spans
            .map((span) => (span.kind, span.range.textInside(source)))
            .toList(),
        [
          (PromptWeightKind.increase, '1.2::haku89 '),
          (PromptWeightKind.delimiter, '::'),
          (PromptWeightKind.decrease, '0.7::blue'),
          (PromptWeightKind.delimiter, '::'),
          (PromptWeightKind.delimiter, '1::'),
          (PromptWeightKind.delimiter, '::'),
        ],
      );
    });

    test('matches NovelAI nested display boundaries', () {
      const source = '1.2::outer, 0.7::inner::, outer::';

      final spans = PromptWeightSyntax.analyze(source).spans;

      expect(
        spans
            .map((span) => (span.kind, span.range.textInside(source)))
            .toList(),
        [
          (PromptWeightKind.increase, '1.2::outer, '),
          (PromptWeightKind.decrease, '0.7::inner'),
          (PromptWeightKind.delimiter, '::'),
          (PromptWeightKind.delimiter, '::'),
        ],
      );
    });

    test('shows the malformed numeric suffix as weight without a closer', () {
      const source = '1.2::haku89::';

      final spans = PromptWeightSyntax.analyze(source).spans;

      expect(spans, hasLength(1));
      expect(spans.single.kind, PromptWeightKind.increase);
      expect(spans.single.range.textInside(source), source);
    });

    test('uses fixed semantics for extreme zero and negative weights', () {
      const source = '9999::high::, 0::zero::, -2::negative::';
      final kinds = PromptWeightSyntax.analyze(source).spans.map(
            (span) => span.kind,
          );

      expect(kinds.where((kind) => kind == PromptWeightKind.increase),
          hasLength(1));
      expect(kinds.where((kind) => kind == PromptWeightKind.decrease),
          hasLength(2));
    });
  });
}
