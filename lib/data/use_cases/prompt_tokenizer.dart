import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

enum PromptTokenizerKind { qwen, t5, clip }

PromptTokenizerKind promptTokenizerFor(String model) =>
    model.contains('diffusion-5')
        ? PromptTokenizerKind.qwen
        : model.contains('diffusion-4')
            ? PromptTokenizerKind.t5
            : PromptTokenizerKind.clip;
int promptTokenLimit(String model) => model.contains('diffusion-5')
    ? (model.contains('curated') ? 703 : 1471)
    : model.contains('diffusion-4')
        ? 512
        : 225;

/// Independently implemented counting algorithms. Definitions are downloaded
/// by the application and cached locally, not redistributed in the application.
abstract class PromptTokenizer {
  int count(String text);
  static PromptTokenizer fromDefinition(
      PromptTokenizerKind kind, Uint8List bytes) {
    final data = jsonDecode(utf8.decode(Inflate(bytes).getBytes()))
        as Map<String, dynamic>;
    return switch (kind) {
      PromptTokenizerKind.qwen => _Bpe.qwen(data),
      PromptTokenizerKind.clip => _Bpe.clip(data),
      PromptTokenizerKind.t5 => _Unigram(data),
    };
  }
}

final _byteAlphabet = () {
  final initial = [
    for (var c = 33; c <= 126; c++) c,
    for (var c = 161; c <= 172; c++) c,
    for (var c = 174; c <= 255; c++) c
  ];
  final result = <int, String>{
    for (final b in initial) b: String.fromCharCode(b)
  };
  var extra = 256;
  for (var b = 0; b < 256; b++) {
    result.putIfAbsent(b, () => String.fromCharCode(extra++));
  }
  return result;
}();

class _Bpe implements PromptTokenizer {
  final Map<String, int> ranks;
  final RegExp pieces;
  final Set<String> specials;
  final bool clip;
  final bool ignoreMerges;
  final Set<String> vocabulary;
  final cache = <String, int>{};
  _Bpe(this.ranks, this.pieces, this.specials, this.clip, this.ignoreMerges,
      this.vocabulary);
  factory _Bpe.qwen(Map<String, dynamic> d) {
    final cfg = d['config'] as Map;
    final special = (d['specialTokens'] as List).cast<String>().toSet();
    final regex =
        '${special.map(RegExp.escape).join('|')}|${cfg['splitRegex']}';
    return _Bpe(
        _ranks(d['merges'] as List),
        RegExp(regex, unicode: true),
        special,
        false,
        cfg['ignoreMerges'] == true,
        cfg['ignoreMerges'] == true
            ? (d['vocab'] as Map).keys.cast<String>().toSet()
            : {});
  }
  factory _Bpe.clip(Map<String, dynamic> d) {
    final merges = (d['text'] as String)
        .split('\n')
        .skip(1)
        .take(49152 - 256 - 2)
        .toList();
    return _Bpe(
        _ranks(merges),
        RegExp(
            r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+",
            unicode: true,
            caseSensitive: false),
        {'<|startoftext|>', '<|endoftext|>'},
        true,
        false,
        {});
  }
  static Map<String, int> _ranks(List<dynamic> merges) => {
        for (var i = 0; i < merges.length; i++)
          (merges[i] is List
              ? (merges[i] as List).join(' ')
              : merges[i] as String): i,
      };
  @override
  int count(String text) {
    if (clip) {
      final entities = HtmlUnescape();
      text = entities
          .convert(entities.convert(text.replaceAll(RegExp(r'[[\]{}]'), ' ')))
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .toLowerCase();
    } else {
      text = unorm.nfc(text);
    }
    var count = 0;
    for (final match in pieces.allMatches(text)) {
      final piece = match[0]!;
      if (specials.contains(piece)) {
        count++;
        continue;
      }
      final cached = cache.remove(piece);
      if (cached != null) {
        cache[piece] = cached;
        count += cached;
        continue;
      }
      var symbols = utf8.encode(piece).map((b) => _byteAlphabet[b]!).toList();
      if (symbols.isEmpty) continue;
      if (clip) symbols[symbols.length - 1] += '</w>';
      if (ignoreMerges && vocabulary.contains(symbols.join())) {
        symbols = [symbols.join()];
      }
      while (symbols.length > 1) {
        var best = 1 << 30, at = -1;
        for (var i = 0; i + 1 < symbols.length; i++) {
          final rank = ranks['${symbols[i]} ${symbols[i + 1]}'];
          if (rank != null && rank < best) {
            best = rank;
            at = i;
          }
        }
        if (at < 0) break;
        final a = symbols[at], b = symbols[at + 1];
        final merged = <String>[];
        for (var i = 0; i < symbols.length; i++) {
          if (i + 1 < symbols.length &&
              symbols[i] == a &&
              symbols[i + 1] == b) {
            merged.add(a + b);
            i++;
          } else {
            merged.add(symbols[i]);
          }
        }
        symbols = merged;
      }
      final n = symbols.length;
      if (piece.length <= 4096) cache[piece] = n;
      if (cache.length > 1024) cache.remove(cache.keys.first);
      count += n;
    }
    return count;
  }
}

class _Trie {
  final edges = <int, _Trie>{};
  double? score;
}

class _Unigram implements PromptTokenizer {
  final root = _Trie();
  late final double unknown;
  final cache = <String, int>{};
  _Unigram(Map<String, dynamic> data) {
    final vocab = (data['model'] as Map)['vocab'] as List;
    unknown = vocab.map((p) => (p[1] as num).toDouble()).reduce(min) - 10;
    for (final entry in vocab) {
      var node = root;
      for (final c in (entry[0] as String).codeUnits) {
        node = node.edges.putIfAbsent(c, _Trie.new);
      }
      node.score = entry[0] == '<unk>' ? unknown : (entry[1] as num).toDouble();
    }
  }
  @override
  int count(String text) {
    if (text.isEmpty) return 1;
    // Match the website's display encoder, including its identity normalizer
    // and UTF-16 fallback units; do not substitute server SentencePiece rules.
    text = text
        .replaceAll(RegExp(r'[[\]{}]'), '')
        .replaceAll(RegExp(r'-?\d*\.?\d*::'), '');
    var total = 1; // T5 display count includes EOS.
    for (final word in text.split(RegExp(r'\s+'))) {
      final piece = word.startsWith('▁') ? word : '▁$word';
      final cached = cache.remove(piece);
      if (cached != null) {
        cache[piece] = cached;
        total += cached;
        continue;
      }
      final n = _countPiece(piece);
      if (piece.length <= 4096) cache[piece] = n;
      if (cache.length > 1024) cache.remove(cache.keys.first);
      total += n;
    }
    return total;
  }

  int _countPiece(String text) {
    final scores = List.filled(text.length + 1, double.negativeInfinity);
    final counts = List.filled(text.length + 1, 0);
    scores[0] = 0;
    for (var start = 0; start < text.length; start++) {
      var node = root;
      var single = false;
      void update(int end, double score) {
        if (scores[start] + score > scores[end]) {
          scores[end] = scores[start] + score;
          counts[end] = counts[start] + 1;
        }
      }

      for (var end = start; end < text.length; end++) {
        final next = node.edges[text.codeUnitAt(end)];
        if (next == null) break;
        node = next;
        if (node.score != null) {
          update(end + 1, node.score!);
          if (end == start) single = true;
        }
      }
      if (!single) update(start + 1, unknown);
    }
    return counts.last;
  }
}

/// The website previews random alternatives before splitting at most six
/// caption chunks. UTF-16 length and last-on-tie match its display transform;
/// this never chooses or rewrites the prompt submitted for generation.
class PromptTokenDisplay {
  static List<String> chunks(String text) {
    final groups = text.split('||');
    for (var i = 1; i < groups.length; i += 2) {
      groups[i] =
          groups[i].split('|').reduce((a, b) => a.length > b.length ? a : b);
    }
    var remaining = groups.join();
    final result = <String>[];
    for (var i = 0; i < 5; i++) {
      final split = remaining.indexOf('|');
      if (split < 0) break;
      result.add(remaining.substring(0, split));
      remaining = remaining.substring(split + 1);
    }
    result.add(remaining);
    return result;
  }

  static int count(
      PromptTokenizer tokenizer, String text, PromptTokenizerKind kind) {
    final counts = chunks(text).map(tokenizer.count);
    // V3 has an independent budget per chunk; expose the largest used budget
    // with that label rather than comparing a sum against one chunk's limit.
    return kind == PromptTokenizerKind.clip
        ? counts.reduce(max)
        : counts.fold(0, (a, b) => a + b);
  }
}
