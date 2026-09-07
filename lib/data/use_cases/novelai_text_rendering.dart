import 'dart:math';

/// A resolved, enabled character from this request, not a random prompt source.
class TextRenderingCharacter {
  final String prompt;
  final Point<double> center;

  const TextRenderingCharacter({required this.prompt, required this.center});
}

/// Builds the V5 frontend's automatic text block from resolved positive prompts.
///
/// Call after prompt composition (including request-only suffixes), never while
/// editing or serializing a user's configuration. Importers can remove a
/// verified automatic block before editing; explicit Text: blocks remain
/// authoritative.
class NovelAiTextRendering {
  static final _manualBlock = RegExp(
    r'(?:^|\s|[,.:[\]{}、。])text:(?!:)',
    caseSensitive: false,
  );
  static final _automaticBlock = RegExp(r'(?:^|\s|[,.:[\]{}、。])teXt:(?!:)');
  static final _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static final _singleQuoteBoundary = RegExp(r'[\s,.]');
  static final _trailingSeparators = RegExp(r'[\s,]+$');
  static final _cjk = RegExp(
    r'[\u3000-\u303F\u3040-\u309F\u30A0-\u30FF\uFF00-\uFF9F\u4E00-\u9FAF\u3400-\u4DBF]',
    unicode: true,
  );
  static const _quotes = {'"': '"', '“': '”', '「': '」', "'": "'", '‘': '’'};

  static String appendToBase(
    String base,
    List<TextRenderingCharacter> characters, {
    required bool useCoords,
  }) {
    final active = characters.where((c) => c.prompt.isNotEmpty).toList();
    if (_manualBlock.hasMatch(base) ||
        active.any((c) => _manualBlock.hasMatch(c.prompt))) {
      return base;
    }
    final boundary = _firstChunkBoundary(base);
    final firstChunk = base.substring(0, boundary);
    final pieces = _renderedText(firstChunk, active, useCoords: useCoords);
    if (pieces.isEmpty) return base;
    final prefix = firstChunk.replaceFirst(_trailingSeparators, '');
    final block = 'teXt: $pieces';
    return '${prefix.isEmpty ? block : '$prefix, $block'}${base.substring(boundary)}';
  }

  /// Matches the frontend's metadata-import rule, not a general text eraser.
  /// Only the exact generated marker AND an exact reconstruction of its text
  /// authorize removal. Other casing, mismatched content and negative prompts
  /// are not normalized. Use original source captions before import cleaning.
  static String removeAutomaticBlock(
    String base,
    List<TextRenderingCharacter> characters, {
    required bool useCoords,
  }) {
    final chunks = <String>[];
    var remaining = base;
    // The website treats at most six chunks; later separators stay in chunk 6.
    for (var i = 0; i < 5; i++) {
      final boundary = _firstChunkBoundary(remaining);
      if (boundary == remaining.length) break;
      chunks.add(remaining.substring(0, boundary));
      remaining = remaining.substring(boundary + 1);
    }
    chunks.add(remaining);
    return chunks.map((chunk) {
      final match = _automaticBlock.firstMatch(chunk);
      if (match == null) return chunk;
      final prefix = chunk.substring(0, match.start);
      final expected = _renderedText(prefix, characters, useCoords: useCoords);
      if (chunk.substring(match.end).trim() != expected) return chunk;
      return prefix.replaceFirst(_trailingSeparators, '');
    }).join('|');
  }

  static String _renderedText(
    String base,
    List<TextRenderingCharacter> characters, {
    required bool useCoords,
  }) {
    final active = characters.where((c) => c.prompt.isNotEmpty).toList();
    final ordered = useCoords ? _readingOrder(active) : active;
    final groups = [
      _quotedPieces(base),
      for (final character in ordered) _quotedPieces(character.prompt),
    ];
    final combined = groups.expand((group) => group).join();
    if (combined.isEmpty) return '';
    // The frontend reverses pieces within each prompt for predominantly CJK
    // dialogue; character ordering itself is still the coordinate/list order.
    final reversePieces =
        _cjk.allMatches(combined).length / combined.length > .3;
    return groups
        .expand((group) => reversePieces ? group.reversed : group)
        .join('\n\n');
  }

  static List<String> _quotedPieces(String prompt) {
    final pieces = <String>[];
    final missingClosers = <String>{};
    var cursor = 0;
    while (cursor < prompt.length) {
      final opening = prompt[cursor];
      final closing = _quotes[opening];
      if (closing == null ||
          missingClosers.contains(closing) ||
          (opening == "'" &&
              cursor > 0 &&
              !_singleQuoteBoundary.hasMatch(prompt[cursor - 1]))) {
        cursor++;
        continue;
      }
      var end = prompt.indexOf(closing, cursor + 1);
      final singleQuote = closing == "'" || closing == '’';
      while (end >= 0 &&
          singleQuote &&
          end + 1 < prompt.length &&
          _letterOrNumber.hasMatch(prompt[end + 1])) {
        end = prompt.indexOf(closing, end + 1);
      }
      if (end < 0) {
        missingClosers.add(closing);
        cursor++;
        continue;
      }
      final piece = prompt.substring(cursor + 1, end).trim();
      if (piece.isNotEmpty) pieces.add(piece);
      cursor = end + 1;
    }
    return pieces;
  }

  // A single | separates chunks, but pipes inside ||random|choices|| do not.
  static int _firstChunkBoundary(String prompt) {
    var inChoices = false;
    for (var i = 0; i < prompt.length; i++) {
      if (prompt[i] != '|') continue;
      if (i + 1 < prompt.length && prompt[i + 1] == '|') {
        inChoices = !inChoices;
        i++;
      } else if (!inChoices) {
        return i;
      }
    }
    return prompt.length;
  }

  static List<TextRenderingCharacter> _readingOrder(
      List<TextRenderingCharacter> characters) {
    // Include the original index for stable ties, matching JavaScript sort.
    final sorted = characters.indexed.toList()
      ..sort((a, b) {
        final order = a.$2.center.y.compareTo(b.$2.center.y);
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
    return _rows(sorted.map((entry) => entry.$2).toList());
  }

  static List<TextRenderingCharacter> _rows(
      List<TextRenderingCharacter> sorted) {
    if (sorted.length <= 1) return sorted;
    var split = 1;
    var largestGap = -1.0;
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i].center.y - sorted[i - 1].center.y;
      if (gap > largestGap) {
        largestGap = gap;
        split = i;
      }
    }
    if (sorted.last.center.y - sorted.first.center.y <= .15 &&
        largestGap <= .1) {
      final row = sorted.indexed.toList()
        ..sort((a, b) {
          final order = a.$2.center.x.compareTo(b.$2.center.x);
          return order == 0 ? a.$1.compareTo(b.$1) : order;
        });
      return row.map((entry) => entry.$2).toList();
    }
    return [
      ..._rows(sorted.sublist(0, split)),
      ..._rows(sorted.sublist(split))
    ];
  }
}
