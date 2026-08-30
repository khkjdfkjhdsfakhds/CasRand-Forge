import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_text_highlighting.dart';

void main() {
  test('handles a representative large segmented prompt synchronously', () {
    const segmentCount = 10000;
    final source = List.filled(segmentCount, 'ab').join();
    final base = TextSpan(
      children: List.generate(
        segmentCount,
        (index) => const TextSpan(text: 'ab'),
        growable: false,
      ),
    );
    final highlights = List.generate(
      segmentCount,
      (index) => PromptTextHighlight(
        range: TextRange(start: index * 2, end: index * 2 + 1),
        style: const TextStyle(backgroundColor: Colors.red),
      ),
      growable: false,
    );

    final result = applyPromptTextHighlights(base, highlights);

    expect(result.toPlainText(), source);
    expect(result.children, hasLength(segmentCount * 2));
  });
}
