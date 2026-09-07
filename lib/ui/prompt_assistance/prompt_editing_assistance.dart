import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_weight_syntax.dart';
import 'package:archive/archive.dart';

/// A single completion candidate from the bundled Danbooru corpus.
class PromptTagCandidate {
  final String tag;
  final int category;
  final int postCount;
  final List<String> aliases;
  final String? translation;
  final List<String> pinyinVariants;

  PromptTagCandidate({
    required this.tag,
    required this.category,
    required this.postCount,
    this.aliases = const [],
    this.translation,
    this.pinyinVariants = const [],
  });

  /// The form shown in the suggestion list.  NovelAI receives [tag].
  String get displayTag => tag.replaceAll('_', ' ');

  /// Optional Chinese label from the bundled community translation map.
  String? get displayTranslation =>
      translation == null || translation!.isEmpty ? null : translation;

  String get categoryLabel => switch (category) {
        0 => 'general',
        1 => 'artist',
        3 => 'copyright',
        4 => 'character',
        5 => 'meta',
        _ => 'other',
      };

  String? _normalizedTag;
  List<String>? _normalizedAliases;

  String get normalizedTag => _normalizedTag ??= normalizePromptTag(tag);

  List<String> get normalizedAliases => _normalizedAliases ??=
      aliases.map(normalizePromptTag).toList(growable: false);

  @override
  bool operator ==(Object other) {
    return other is PromptTagCandidate &&
        other.tag == tag &&
        other.category == category &&
        other.postCount == postCount &&
        listEquals(other.aliases, aliases) &&
        other.translation == translation &&
        listEquals(other.pinyinVariants, pinyinVariants);
  }

  @override
  int get hashCode => Object.hash(tag, category, postCount,
      Object.hashAll(aliases), translation, Object.hashAll(pinyinVariants));
}

/// Text and selection passed through the shared completion seam.
class PromptCompletionRequest {
  final String text;
  final TextSelection selection;
  final bool enabled;
  final bool composing;

  const PromptCompletionRequest({
    required this.text,
    required this.selection,
    this.enabled = true,
    this.composing = false,
  });
}

/// The candidates and the exact range that accepting one will replace.
class PromptCompletionResult {
  final String sourceText;
  final TextRange replacementRange;
  final String query;
  final List<PromptTagCandidate> candidates;

  const PromptCompletionResult({
    required this.sourceText,
    required this.replacementRange,
    required this.query,
    required this.candidates,
  });

  bool get isEmpty => candidates.isEmpty;

  /// Whether this asynchronous result still describes the value currently in
  /// an editor.  A prompt can keep the same text while the user moves the
  /// caret, so checking [sourceText] alone is not enough before acceptance.
  bool matches(TextEditingValue value) {
    final selection = value.selection;
    if (value.text != sourceText ||
        (value.composing.isValid && !value.composing.isCollapsed) ||
        !selection.isValid ||
        !selection.isCollapsed ||
        selection.extentOffset != replacementRange.end ||
        replacementRange.start < 0 ||
        replacementRange.end > value.text.length) {
      return false;
    }
    final fragment = value.text.substring(
      replacementRange.start,
      replacementRange.end,
    );
    return normalizePromptTag(fragment) == query;
  }

  TextEditingValue accept(
    PromptTagCandidate candidate, {
    TextSelection? currentSelection,
  }) {
    const suffix = ', ';
    final completedTag = '${candidate.tag}$suffix';
    final newText = sourceText.replaceRange(
      replacementRange.start,
      replacementRange.end,
      completedTag,
    );
    final offset = replacementRange.start + completedTag.length;
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

/// Shared interface used by fixed and cascaded prompt editors.
///
/// This first ticket implements completion.  Weight and position operations
/// deliberately belong here in later tickets so both editor families can use
/// the same text/selection semantics instead of copying parser logic.
class PromptEditingAssistance {
  static const assetPath = 'assets/prompt_assistance/danbooru-index.json.gz';
  static const translationAssetPath =
      'assets/prompt_assistance/danbooru-translations.json.gz';
  static const suggestionLimit = 12;

  static PromptEditingAssistance? _shared;

  final Future<DanbooruTagIndex> _indexFuture;

  PromptEditingAssistance({Future<DanbooruTagIndex>? index})
      : _indexFuture = index ?? _loadBundledIndex();

  factory PromptEditingAssistance.fromCandidates(
    Iterable<PromptTagCandidate> candidates,
  ) {
    return PromptEditingAssistance(
      index: Future.value(DanbooruTagIndex(candidates.toList(growable: false))),
    );
  }

  /// One lazily-created cache is shared by all prompt fields in the process.
  static PromptEditingAssistance get shared =>
      _shared ??= PromptEditingAssistance();

  /// Exposed for tests and for a future explicit cache warm-up indicator.
  Future<DanbooruTagIndex> get ready => _indexFuture;

  Future<PromptCompletionResult> complete(
    PromptCompletionRequest request,
  ) async {
    final fragment = PromptFragment.fromRequest(request);
    if (fragment == null) {
      return PromptCompletionResult(
        sourceText: request.text,
        replacementRange: TextRange.collapsed(request.selection.extentOffset),
        query: '',
        candidates: const [],
      );
    }
    final index = await _indexFuture;
    return PromptCompletionResult(
      sourceText: request.text,
      replacementRange: fragment.range,
      query: fragment.query,
      candidates: index.search(fragment.query),
    );
  }

  static Future<DanbooruTagIndex> _loadBundledIndex() async {
    final indexData = await rootBundle.load(assetPath);
    final translationData = await rootBundle.load(translationAssetPath);
    // Decompression and object construction happen in a worker isolate.  The
    // editor can render and accept ordinary text while this future is pending.
    return compute(
      _decodeBundledIndex,
      <String, Uint8List>{
        'index': indexData.buffer
            .asUint8List(indexData.offsetInBytes, indexData.lengthInBytes),
        'translations': translationData.buffer.asUint8List(
          translationData.offsetInBytes,
          translationData.lengthInBytes,
        ),
      },
    );
  }
}

/// The searchable, immutable index.  Keeping this type public gives future
/// editor adapters a small deterministic seam without exposing parsing code.
class DanbooruTagIndex {
  final List<PromptTagCandidate> entries;

  late final List<_PromptPrefixRecord> _canonicalPrefixes;
  late final List<_PromptPrefixRecord> _aliasPrefixes;
  late final Map<String, List<int>> _substringBuckets;
  late final List<_PromptPrefixRecord> _translationPrefixes;
  late final List<_PromptPrefixRecord> _pinyinPrefixes;
  bool _indexesBuilt = false;

  DanbooruTagIndex(Iterable<PromptTagCandidate> source)
      : entries = List.unmodifiable(source) {
    // The bundled index is constructed inside compute() so this one-time
    // indexing work stays off the UI isolate. Small test/editor indexes pay
    // the same deterministic setup cost and share exactly the same search
    // behavior.
    warmUp();
  }

  int get length => entries.length;

  /// Materialize normalized lookup values while the index is being prepared,
  /// rather than paying that cost on the first keystroke.
  void warmUp() {
    if (_indexesBuilt) return;
    for (final entry in entries) {
      entry.normalizedTag;
      entry.normalizedAliases;
    }

    final canonicalPrefixes = <_PromptPrefixRecord>[];
    final aliasPrefixes = <_PromptPrefixRecord>[];
    final translationPrefixes = <_PromptPrefixRecord>[];
    final pinyinPrefixes = <_PromptPrefixRecord>[];
    final substringBuckets = <String, List<int>>{};
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      canonicalPrefixes.add(
        _PromptPrefixRecord(key: entry.normalizedTag, entryIndex: index),
      );
      for (final alias in entry.normalizedAliases) {
        if (alias.isNotEmpty) {
          aliasPrefixes.add(
            _PromptPrefixRecord(key: alias, entryIndex: index),
          );
        }
      }
      final translation = normalizePromptTag(entry.translation ?? '');
      if (translation.isNotEmpty) {
        translationPrefixes.add(
          _PromptPrefixRecord(key: translation, entryIndex: index),
        );
      }
      for (final pinyin in entry.pinyinVariants) {
        if (pinyin.isNotEmpty) {
          pinyinPrefixes.add(
            _PromptPrefixRecord(key: pinyin, entryIndex: index),
          );
        }
      }

      // Substring matching is backed by unique two-character buckets. A
      // candidate is added once per bucket even when the same pair occurs
      // repeatedly in its canonical tag. Search picks the rarest bucket for
      // each query, then verifies the full substring, avoiding a 140k scan.
      final seenPairs = <String>{};
      final tag = entry.normalizedTag;
      for (var offset = 0; offset + 1 < tag.length; offset++) {
        final pair = tag.substring(offset, offset + 2);
        if (seenPairs.add(pair)) {
          substringBuckets.putIfAbsent(pair, () => <int>[]).add(index);
        }
      }
    }
    canonicalPrefixes.sort(
      (a, b) => _comparePrefixRecords(a, b, entries),
    );
    aliasPrefixes.sort(
      (a, b) => _comparePrefixRecords(a, b, entries),
    );
    translationPrefixes.sort(
      (a, b) => _comparePrefixRecords(a, b, entries),
    );
    pinyinPrefixes.sort(
      (a, b) => _comparePrefixRecords(a, b, entries),
    );
    for (final bucket in substringBuckets.values) {
      bucket.sort((a, b) => _compareEntryIndexes(a, b, entries));
    }
    _canonicalPrefixes = List.unmodifiable(canonicalPrefixes);
    _aliasPrefixes = List.unmodifiable(aliasPrefixes);
    _translationPrefixes = List.unmodifiable(translationPrefixes);
    _pinyinPrefixes = List.unmodifiable(pinyinPrefixes);
    _substringBuckets = Map.unmodifiable(substringBuckets);
    _indexesBuilt = true;
  }

  List<PromptTagCandidate> search(
    String query, {
    int limit = PromptEditingAssistance.suggestionLimit,
  }) {
    final normalizedQuery = normalizePromptTag(query);
    if (normalizedQuery.length < 2 || limit <= 0) return const [];

    if (!_indexesBuilt) warmUp();
    final isPinyin = normalizedQuery.startsWith('/');
    final searchQuery =
        isPinyin ? normalizedQuery.substring(1) : normalizedQuery;
    if (searchQuery.length < 2) return const [];
    final canonical = _bestEntryIndexes(
      _prefixEntryIndexes(
          isPinyin ? _pinyinPrefixes : _canonicalPrefixes, searchQuery),
      limit,
      entries: entries,
    );
    final selected = canonical.toSet();
    if (!isPinyin && canonical.length < limit) {
      final aliases = _bestEntryIndexes(
        _prefixEntryIndexes(_aliasPrefixes, normalizedQuery),
        limit - canonical.length,
        entries: entries,
        excluded: selected,
      );
      canonical.addAll(aliases);
      selected.addAll(aliases);
    }
    if (!isPinyin && canonical.length < limit) {
      final translations = _bestEntryIndexes(
        _prefixEntryIndexes(_translationPrefixes, searchQuery),
        limit - canonical.length,
        entries: entries,
        excluded: selected,
      );
      canonical.addAll(translations);
      selected.addAll(translations);
    }
    if (!isPinyin && canonical.length < limit) {
      final substring = _bestEntryIndexes(
        _substringEntryIndexes(
          normalizedQuery,
          entries,
          _substringBuckets,
        ),
        limit - canonical.length,
        entries: entries,
        excluded: selected,
      );
      canonical.addAll(substring);
    }
    return canonical
        .map((entryIndex) => entries[entryIndex])
        .toList(growable: false);
  }
}

class _PromptPrefixRecord {
  final String key;
  final int entryIndex;

  const _PromptPrefixRecord({required this.key, required this.entryIndex});
}

int _comparePrefixRecords(
  _PromptPrefixRecord a,
  _PromptPrefixRecord b,
  List<PromptTagCandidate> entries,
) {
  final key = a.key.compareTo(b.key);
  if (key != 0) return key;
  return _compareEntryIndexes(a.entryIndex, b.entryIndex, entries);
}

int _compareEntryIndexes(
  int a,
  int b,
  List<PromptTagCandidate> entries,
) {
  final aEntry = entries[a];
  final bEntry = entries[b];
  final count = bEntry.postCount.compareTo(aEntry.postCount);
  if (count != 0) return count;
  final tag = aEntry.normalizedTag.compareTo(bEntry.normalizedTag);
  if (tag != 0) return tag;
  final category = aEntry.category.compareTo(bEntry.category);
  if (category != 0) return category;
  return a.compareTo(b);
}

Iterable<int> _prefixEntryIndexes(
  List<_PromptPrefixRecord> records,
  String query,
) sync* {
  var low = 0;
  var high = records.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (records[middle].key.compareTo(query) < 0) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  for (var index = low;
      index < records.length && records[index].key.startsWith(query);
      index++) {
    yield records[index].entryIndex;
  }
}

Iterable<int> _substringEntryIndexes(
  String query,
  List<PromptTagCandidate> entries,
  Map<String, List<int>> buckets,
) sync* {
  List<int>? rarest;
  final seenPairs = <String>{};
  for (var offset = 0; offset + 1 < query.length; offset++) {
    final pair = query.substring(offset, offset + 2);
    if (!seenPairs.add(pair)) continue;
    final bucket = buckets[pair];
    if (bucket == null) return;
    if (rarest == null || bucket.length < rarest.length) rarest = bucket;
  }
  if (rarest == null) return;
  for (final entryIndex in rarest) {
    if (entries[entryIndex].normalizedTag.contains(query)) {
      yield entryIndex;
    }
  }
}

List<int> _bestEntryIndexes(
  Iterable<int> candidates,
  int limit, {
  required List<PromptTagCandidate> entries,
  Set<int>? excluded,
}) {
  if (limit <= 0) return <int>[];
  final seen = <int>{};
  final best = <int>[];
  for (final entryIndex in candidates) {
    if (!seen.add(entryIndex) || excluded?.contains(entryIndex) == true) {
      continue;
    }
    var insertion = 0;
    while (insertion < best.length &&
        _compareEntryIndexes(best[insertion], entryIndex, entries) <= 0) {
      insertion++;
    }
    if (insertion >= limit && best.length >= limit) continue;
    best.insert(insertion, entryIndex);
    if (best.length > limit) best.removeLast();
  }
  return best;
}

String normalizePromptTag(String value) {
  return value.trim().replaceAll(_tagWhitespace, '_').toLowerCase();
}

final _tagWhitespace = RegExp(r'\s+');
final _numericPromptFragment = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$');

class PromptFragment {
  final TextRange range;
  final String query;

  const PromptFragment({required this.range, required this.query});

  static PromptFragment? fromRequest(PromptCompletionRequest request) {
    if (!request.enabled || request.composing) return null;
    final selection = request.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final offset = selection.extentOffset;
    if (offset < 0 || offset > request.text.length) return null;

    final beforeCaret = request.text.substring(0, offset);
    final lineStart = beforeCaret.lastIndexOf('\n') + 1;
    final lineEnd = request.text.indexOf('\n', offset);
    final line = request.text.substring(
      lineStart,
      lineEnd == -1 ? request.text.length : lineEnd,
    );
    if (line.trimLeft().startsWith('#')) return null;

    var fragmentStart = lineStart;
    for (var index = offset - 1; index >= lineStart; index--) {
      final character = request.text[index];
      if (character == ',' || character == '，') {
        fragmentStart = index + 1;
        break;
      }
    }

    var tokenStart = fragmentStart;
    while (tokenStart < offset &&
        (request.text[tokenStart] == ' ' ||
            request.text[tokenStart] == '\t' ||
            request.text[tokenStart] == '　')) {
      tokenStart++;
    }
    var rawQuery = request.text.substring(tokenStart, offset);
    var queryStart = tokenStart;

    final weightSeparator = rawQuery.lastIndexOf('::');
    if (weightSeparator != -1) {
      queryStart += weightSeparator + 2;
      rawQuery = rawQuery.substring(weightSeparator + 2);
      while (queryStart < offset &&
          (request.text[queryStart] == ' ' ||
              request.text[queryStart] == '\t' ||
              request.text[queryStart] == '{' ||
              request.text[queryStart] == '[')) {
        queryStart++;
      }
      rawQuery = request.text.substring(queryStart, offset);
    } else {
      while (queryStart < offset &&
          (request.text[queryStart] == '(' ||
              request.text[queryStart] == '{' ||
              request.text[queryStart] == '[')) {
        queryStart++;
      }
      rawQuery = request.text.substring(queryStart, offset);
    }

    final query = normalizePromptTag(rawQuery);
    if (query.length < 2 || _numericPromptFragment.hasMatch(query)) {
      return null;
    }
    if (query.contains('__') || query.contains('\$') || query.contains('{{')) {
      return null;
    }
    return PromptFragment(
      range: TextRange(start: queryStart, end: offset),
      query: query,
    );
  }
}

DanbooruTagIndex _decodeBundledIndex(Map<String, Uint8List> assetBytes) {
  final compressed = GZipDecoder().decodeBytes(assetBytes['index']!);
  final decoded = jsonDecode(utf8.decode(compressed));
  if (decoded is! List) {
    throw const FormatException('Danbooru index must be a JSON array');
  }
  final translationPayload = jsonDecode(utf8.decode(
    GZipDecoder().decodeBytes(assetBytes['translations']!),
  ));
  final translations = <String, String>{};
  final pinyinMap = <String, String>{};
  if (translationPayload is Map) {
    final rawTranslations = translationPayload['translations'];
    if (rawTranslations is Map) {
      rawTranslations.forEach((key, value) {
        if (key is String && value is String && value.isNotEmpty) {
          translations[key] = value;
        }
      });
    }
    final rawPinyin = translationPayload['pinyin'];
    if (rawPinyin is Map) {
      rawPinyin.forEach((key, value) {
        if (key is String && value is String && value.isNotEmpty) {
          pinyinMap[key] = value;
        }
      });
    }
  }
  final entries = <PromptTagCandidate>[];
  for (final row in decoded) {
    if (row is! List || row.length != 4) {
      throw const FormatException('Danbooru index row has an invalid shape');
    }
    final aliases = row[3] is List
        ? (row[3] as List).whereType<String>().toList(growable: false)
        : const <String>[];
    final translation = translations[row[0] as String];
    final pinyin = <String>{};
    if (translation != null) {
      for (final segment in translation.split(RegExp(r'[|/(),\s]+'))) {
        if (segment.isEmpty) continue;
        var full = StringBuffer();
        var initials = StringBuffer();
        for (final character in segment.runes.map(String.fromCharCode)) {
          final syllable = pinyinMap[character];
          if (syllable != null) {
            full.write(syllable);
            initials.write(syllable[0]);
          } else if (RegExp(r'[A-Za-z0-9]').hasMatch(character)) {
            full.write(character.toLowerCase());
            initials.write(character.toLowerCase());
          }
        }
        if (full.isNotEmpty) {
          pinyin.add(full.toString());
          pinyin.add(initials.toString());
          pinyin.add(full.toString().replaceAll('nv', 'nu'));
          pinyin.add(full.toString().replaceAll('lv', 'lu'));
        }
      }
    }
    entries.add(
      PromptTagCandidate(
        tag: row[0] as String,
        category: (row[1] as num).toInt(),
        postCount: (row[2] as num).toInt(),
        aliases: aliases,
        translation: translation,
        pinyinVariants: pinyin.toList(growable: false),
      ),
    );
  }
  final index = DanbooruTagIndex(entries);
  index.warmUp();
  return index;
}

/// A text field adapter for the shared completion seam.
class PromptAssistedTextField extends StatefulWidget {
  const PromptAssistedTextField({
    super.key,
    required this.initialValue,
    required this.onChanged,
    this.enabled = true,
    this.assistance,
    this.hintText,
    this.fieldKey,
    this.minLines = 3,
    this.maxLines = 8,
    this.onKeyEvent,
    this.completionEnabled = true,
    this.controller,
    this.focusNode,
    this.fieldBuilder,
    this.onExternalEdit,
    this.refreshController,
    this.normalizeWeightOnFocusLoss = false,
  });

  final String initialValue;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final PromptEditingAssistance? assistance;
  final String? hintText;
  final Key? fieldKey;
  final int minLines;
  final int maxLines;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;

  /// An existing controller can be supplied by an editor that has additional
  /// document semantics (for example cascaded entry boundaries).  The shared
  /// completion state observes and edits that controller without replacing its
  /// formatter, selection or undo implementation.
  final TextEditingController? controller;

  /// An existing focus node can be supplied when the editor already owns its
  /// keyboard handler.  The shared autocomplete listens to the same node, so
  /// IME and editor-specific shortcuts retain their priority.
  final FocusNode? focusNode;

  /// Builds the editable surface while retaining the shared completion and
  /// options behavior.  The callback receives the shared controller, focus
  /// node, and change callback.  [loading] is true while the local index is
  /// preparing for the current fragment.
  final Widget Function(
    BuildContext context,
    TextEditingController controller,
    FocusNode focusNode,
    ValueChanged<String> onChanged,
    bool loading,
  )? fieldBuilder;

  /// Invoked immediately before an accepted completion is assigned to an
  /// externally-owned controller.  Adapters use the exact replacement range
  /// to remap document metadata (such as cascaded entry boundaries).
  final void Function(
    TextEditingValue oldValue,
    TextEditingValue newValue,
    TextRange replacementRange,
  )? onExternalEdit;

  /// Optional listener wake-up for an externally-owned controller after async
  /// candidates are published.  A document controller can expose a public
  /// wrapper around its protected [ChangeNotifier.notifyListeners] method.
  final VoidCallback? refreshController;

  /// Treats focus loss as confirmation for fixed prompt fields, which do not
  /// have an explicit Confirm action.
  final bool normalizeWeightOnFocusLoss;

  /// Keeps the field editable while suppressing only the completion popup.
  /// Weight and position shortcuts remain available when this is false.
  final bool completionEnabled;

  @override
  PromptAssistedTextFieldState createState() => PromptAssistedTextFieldState();
}

class PromptAssistedTextFieldState extends State<PromptAssistedTextField> {
  late final TextEditingController _controller;
  late TextEditingValue _lastControllerValue;
  late final FocusNode _focusNode;
  late final bool _ownsController;
  late final bool _ownsFocusNode;
  KeyEventResult Function(FocusNode node, KeyEvent event)?
      _previousExternalKeyHandler;
  KeyEventResult Function(FocusNode node, KeyEvent event)?
      _wrappedExternalKeyHandler;
  late final PromptEditingAssistance _assistance;
  PromptCompletionResult? _result;
  List<PromptTagCandidate> _candidates = const [];
  int _requestId = 0;
  int _optionsRevision = 0;
  int _highlightedIndex = 0;
  bool _loading = false;
  bool _accepting = false;
  PromptCompletionRequest? _pendingRequest;
  late final OverlayPortalController _optionsPortalController;
  late final GlobalKey _fieldLayoutKey;
  late final ScrollController _optionsScrollController;
  final Map<String, GlobalKey> _candidateItemKeys = <String, GlobalKey>{};

  /// Current value for a thin adapter handling shared keyboard transforms.
  TextEditingValue get editingValue => _controller.value;

  /// Re-evaluates completion for the current text and selection. Adapters can
  /// call this after programmatic caret changes without synthesizing a text
  /// edit while the field is focused.
  void requestCompletion() {
    if (!_focusNode.hasFocus) {
      _hideSuggestions();
      return;
    }
    _handleChanged(_controller.text);
  }

  /// Applies a complete edit (including its selection) without synthesizing a
  /// completion request. The adapter owns persistence/undo recording and
  /// should call its `onChanged` callback after this assignment.
  void setEditingValue(TextEditingValue value) {
    _accepting = true;
    _controller.value = value;
    _accepting = false;
    _hideSuggestions();
    _focusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    final suppliedController = widget.controller;
    _ownsController = suppliedController == null;
    _controller = suppliedController ??
        _PromptTextEditingController(text: widget.initialValue);
    _lastControllerValue = _controller.value;
    final suppliedFocusNode = widget.focusNode;
    _ownsFocusNode = suppliedFocusNode == null;
    _focusNode = suppliedFocusNode ?? FocusNode(onKeyEvent: _handleKeyEvent);
    _optionsPortalController = OverlayPortalController(
      debugLabel: 'prompt-assistance-options',
    );
    _fieldLayoutKey = GlobalKey();
    _optionsScrollController = ScrollController();
    _focusNode.addListener(_handleFocusChanged);
    if (suppliedFocusNode != null) {
      _previousExternalKeyHandler = suppliedFocusNode.onKeyEvent;
      _wrappedExternalKeyHandler = (node, event) {
        final hardware = HardwareKeyboard.instance;
        final completionKey = event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.tab ||
            event.logicalKey == LogicalKeyboardKey.escape;
        if (!hardware.isControlPressed &&
            !hardware.isMetaPressed &&
            !hardware.isAltPressed &&
            completionKey &&
            _candidates.isNotEmpty) {
          final completionResult =
              _handleKeyEvent(node, event, invokeCustom: false);
          if (completionResult != KeyEventResult.ignored) {
            return completionResult;
          }
        }
        final previous = _previousExternalKeyHandler;
        final previousResult = previous?.call(node, event);
        if (previousResult != null &&
            previousResult != KeyEventResult.ignored) {
          return previousResult;
        }
        return _handleKeyEvent(node, event, invokeCustom: false);
      };
      suppliedFocusNode.onKeyEvent = _wrappedExternalKeyHandler;
    }
    _controller.addListener(_handleControllerChanged);
    _assistance = widget.assistance ?? PromptEditingAssistance.shared;
  }

  @override
  void didUpdateWidget(covariant PromptAssistedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.enabled && !widget.enabled) ||
        (oldWidget.completionEnabled && !widget.completionEnabled)) {
      _hideSuggestions();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _optionsScrollController.dispose();
    if (!_ownsFocusNode &&
        identical(_focusNode.onKeyEvent, _wrappedExternalKeyHandler)) {
      _focusNode.onKeyEvent = _previousExternalKeyHandler;
    }
    if (_ownsFocusNode) _focusNode.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      if (widget.normalizeWeightOnFocusLoss) {
        final normalized = PromptWeightSyntax.normalizeAll(_controller.value);
        if (normalized != _controller.value) {
          _accepting = true;
          _controller.value = normalized;
          _accepting = false;
          widget.onChanged(normalized.text);
        }
      }
      _hideSuggestions();
    } else if (_result != null && _candidates.isNotEmpty) {
      _syncOptionsOverlay();
    }
  }

  void _handleControllerChanged() {
    final previousValue = _lastControllerValue;
    final currentValue = _controller.value;
    _lastControllerValue = currentValue;
    if (_accepting) return;
    if (previousValue.composing.isValid &&
        !previousValue.composing.isCollapsed &&
        (!currentValue.composing.isValid ||
            currentValue.composing.isCollapsed)) {
      final normalized = PromptWeightSyntax.normalizeEdit(
        previousValue,
        currentValue,
      );
      if (normalized != currentValue) {
        _accepting = true;
        _controller.value = normalized;
        _accepting = false;
        widget.onChanged(normalized.text);
        return;
      }
    }
    final result = _result;
    if (result != null && !result.matches(_controller.value)) {
      final sameText = _controller.text == result.sourceText;
      _hideSuggestions();
      if (sameText) {
        final value = _controller.value;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _controller.value != value) return;
          _startCompletion();
        });
      }
      return;
    }
    final pending = _pendingRequest;
    if (_loading && pending != null && !_requestMatchesCurrent(pending)) {
      final textChanged = pending.text != _controller.text;
      _requestId++;
      _pendingRequest = null;
      if (mounted) {
        setState(() {
          _loading = false;
          _candidates = const [];
          _result = null;
          _highlightedIndex = 0;
          _optionsRevision++;
        });
        _syncOptionsOverlay();
      }
      // A caret-only move should query the new fragment without notifying the
      // editor adapter as though text had changed.  Text edits are delivered
      // through onChanged, which starts the replacement request itself; do
      // not schedule a second request from this controller listener.
      if (textChanged) return;
      final value = _controller.value;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _controller.value != value) return;
        _startCompletion();
      });
      return;
    }
    if (result != null && _candidates.isNotEmpty) {
      _scheduleOptionsLayout();
    }
  }

  bool _requestMatchesCurrent(PromptCompletionRequest request) {
    final value = _controller.value;
    final composing = value.composing.isValid && !value.composing.isCollapsed;
    return value.text == request.text &&
        value.selection == request.selection &&
        composing == request.composing;
  }

  void _scheduleOptionsLayout() {
    if (!mounted || _result == null || _candidates.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _result == null || _candidates.isEmpty) return;
      setState(() {});
    });
  }

  void _syncOptionsOverlay() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_focusNode.hasFocus && _result != null && _candidates.isNotEmpty) {
        _optionsPortalController.show();
      } else {
        _optionsPortalController.hide();
      }
    });
  }

  RenderEditable? _findRenderEditable() {
    final renderObject = _fieldLayoutKey.currentContext?.findRenderObject();
    if (renderObject == null) return null;
    RenderEditable? editable;
    void visit(RenderObject child) {
      if (editable != null) return;
      if (child is RenderEditable) {
        editable = child;
        return;
      }
      child.visitChildren(visit);
    }

    visit(renderObject);
    return editable;
  }

  GlobalKey _candidateItemKey(String tag) {
    return _candidateItemKeys.putIfAbsent(tag, GlobalKey.new);
  }

  void _ensureHighlightedVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _candidates.isEmpty) return;
      final candidate = _candidates[_highlightedIndex];
      final context = _candidateItemKeys[candidate.tag]?.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: Duration.zero,
      );
    });
  }

  KeyEventResult _handleKeyEvent(
    FocusNode node,
    KeyEvent event, {
    bool invokeCustom = true,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_controller.value.composing.isValid &&
        !_controller.value.composing.isCollapsed) {
      _hideSuggestions();
      return KeyEventResult.ignored;
    }
    if (invokeCustom) {
      final customResult = widget.onKeyEvent?.call(node, event);
      if (customResult != null && customResult != KeyEventResult.ignored) {
        return customResult;
      }
    }
    final hardware = HardwareKeyboard.instance;
    // Modified arrows belong to the shared weight/position seam.  Completion
    // navigation only handles unmodified arrows so later adapters can attach
    // Control+Up/Down/Left/Right without fighting this field.
    if (hardware.isControlPressed ||
        hardware.isMetaPressed ||
        hardware.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (_candidates.isEmpty || _result == null) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      setState(() {
        _highlightedIndex = (_highlightedIndex + 1) % _candidates.length;
      });
      _ensureHighlightedVisible();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      setState(() {
        _highlightedIndex =
            (_highlightedIndex - 1 + _candidates.length) % _candidates.length;
      });
      _ensureHighlightedVisible();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _hideSuggestions();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      _acceptCandidate(_candidates[_highlightedIndex]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleChanged(String value) {
    if (_accepting) return;
    widget.onChanged(value);
    _startCompletion();
  }

  void _startCompletion() {
    if (_accepting) return;
    if (!_focusNode.hasFocus) {
      _pendingRequest = null;
      _hideSuggestions();
      return;
    }
    if (!widget.enabled ||
        !widget.completionEnabled ||
        widget.assistance == null) {
      _pendingRequest = null;
      return;
    }
    final requestId = ++_requestId;
    final request = PromptCompletionRequest(
      text: _controller.text,
      selection: _controller.selection,
      enabled: widget.enabled && widget.completionEnabled,
      composing: _controller.value.composing.isValid &&
          !_controller.value.composing.isCollapsed,
    );
    _pendingRequest = request;
    final fragment = PromptFragment.fromRequest(request);
    if (fragment == null) {
      _pendingRequest = null;
      _hideSuggestions();
      return;
    }
    setState(() {
      _loading = true;
      _candidates = const [];
      _result = null;
      _highlightedIndex = 0;
    });
    _syncOptionsOverlay();
    _assistance.complete(request).then((result) {
      if (!mounted ||
          requestId != _requestId ||
          !_requestMatchesCurrent(request)) {
        if (requestId == _requestId) {
          _pendingRequest = null;
          _hideSuggestions();
        }
        return;
      }
      _pendingRequest = null;
      setState(() {
        _loading = false;
        _result = result;
        _candidates = result.candidates;
        _highlightedIndex = 0;
        _optionsRevision++;
      });
      _syncOptionsOverlay();
      // RawAutocomplete listens to the controller for opening/closing its
      // options overlay.  The async index result does not change the text, so
      // explicitly wake that listener after publishing the candidates.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && requestId == _requestId) {
          if (_controller case final _PromptTextEditingController controller) {
            controller.refresh();
          } else {
            final refresh = widget.refreshController;
            if (refresh != null) {
              refresh();
            } else if (mounted) {
              // Rebuild as a last resort for plain external controllers.
              setState(() {});
            }
          }
        }
      });
    });
  }

  void _acceptCandidate(PromptTagCandidate candidate) {
    final result = _result;
    final current = _controller.value;
    if (result == null || !result.matches(current)) {
      _hideSuggestions();
      return;
    }
    _accepting = true;
    final value = result.accept(candidate, currentSelection: current.selection);
    widget.onExternalEdit?.call(current, value, result.replacementRange);
    _controller.value = value;
    _accepting = false;
    widget.onChanged(value.text);
    _hideSuggestions();
    _focusNode.requestFocus();
  }

  void _hideSuggestions() {
    _requestId++;
    _pendingRequest = null;
    if (!mounted) return;
    if (!_loading && _result == null && _candidates.isEmpty) {
      _syncOptionsOverlay();
      return;
    }
    setState(() {
      _loading = false;
      _result = null;
      _candidates = const [];
      _highlightedIndex = 0;
      _optionsRevision++;
    });
    _syncOptionsOverlay();
  }

  Widget _buildFieldView(
    BuildContext context,
    TextEditingController controller,
    FocusNode focusNode,
  ) {
    final builder = widget.fieldBuilder;
    final field = builder != null
        ? builder(
            context,
            controller,
            focusNode,
            _handleChanged,
            _loading,
          )
        : TextField(
            key: widget.fieldKey ?? const Key('prompt-assisted-text-field'),
            controller: controller,
            focusNode: focusNode,
            enabled: widget.enabled,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            keyboardType: TextInputType.multiline,
            inputFormatters: const [PromptWeightSafetyFormatter()],
            decoration: InputDecoration(
              hintText: widget.hintText,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
              suffixIcon: _loading
                  ? const Padding(
                      key: Key('prompt-assistance-loading'),
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            onChanged: _handleChanged,
          );
    return KeyedSubtree(
      key: _fieldLayoutKey,
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          _scheduleOptionsLayout();
          return false;
        },
        child: field,
      ),
    );
  }

  Widget _buildOptionsSurface(double maxWidth) {
    final values = _candidates;
    return Material(
      key: const Key('prompt-assistance-options'),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: math.min(280, maxWidth),
          maxWidth: maxWidth,
          maxHeight: 280,
        ),
        child: ListView.builder(
          controller: _optionsScrollController,
          padding: const EdgeInsets.symmetric(vertical: 4),
          primary: false,
          shrinkWrap: true,
          itemCount: values.length,
          itemBuilder: (context, index) {
            final candidate = values[index];
            final selected = index == _highlightedIndex;
            return KeyedSubtree(
              key: _candidateItemKey(candidate.tag),
              child: Listener(
                onPointerDown: (event) {
                  if (event.kind == PointerDeviceKind.mouse &&
                      event.buttons == kPrimaryButton) {
                    _acceptCandidate(candidate);
                  }
                },
                child: InkWell(
                  onTap: () => _acceptCandidate(candidate),
                  child: ListTile(
                    key: Key('prompt-assistance-candidate-${candidate.tag}'),
                    selected: selected,
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    minVerticalPadding: 2,
                    visualDensity: const VisualDensity(vertical: -3),
                    title: Text(candidate.displayTag),
                    subtitle: Text(
                      [
                        if (candidate.displayTranslation != null)
                          candidate.displayTranslation!,
                        candidate.categoryLabel,
                        candidate.postCount.toString(),
                      ].join(' · '),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildOptionsOverlay(
    BuildContext context,
    OverlayChildLayoutInfo layoutInfo,
  ) {
    if (_result == null || _candidates.isEmpty) {
      return const SizedBox.shrink();
    }
    final editable = _findRenderEditable();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (editable == null || overlay is! RenderBox) {
      return const SizedBox.shrink();
    }
    final selection = _controller.selection;
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: selection.extentOffset),
    );
    final caretTopLeft = overlay.globalToLocal(
      editable.localToGlobal(caret.topLeft),
    );
    final caretBottomRight = overlay.globalToLocal(
      editable.localToGlobal(caret.bottomRight),
    );
    final caretRect = Rect.fromPoints(caretTopLeft, caretBottomRight);
    // OverlayPortal builds its child in the root Overlay context, which can
    // sit outside a dialog/IME-specific MediaQuery. Read the field's own
    // inherited metrics first so a route-local safe area is respected.
    final fieldMediaQuery = _fieldLayoutKey.currentContext == null
        ? null
        : MediaQuery.maybeOf(_fieldLayoutKey.currentContext!);
    final mediaQuery = fieldMediaQuery ?? MediaQuery.maybeOf(context);
    final mediaPadding = mediaQuery?.padding ?? EdgeInsets.zero;
    final viewInsets = mediaQuery?.viewInsets ?? EdgeInsets.zero;
    final overlayBounds = Offset.zero & layoutInfo.overlaySize;
    final safeRect = Rect.fromLTRB(
      math.max(
        overlayBounds.left,
        math.min(overlayBounds.right, mediaPadding.left),
      ),
      math.max(
        overlayBounds.top,
        math.min(
            overlayBounds.bottom, math.max(mediaPadding.top, viewInsets.top)),
      ),
      math.min(
        overlayBounds.right,
        math.max(overlayBounds.left, overlayBounds.right - mediaPadding.right),
      ),
      math.min(
        overlayBounds.bottom,
        math.max(
          overlayBounds.top,
          overlayBounds.bottom -
              math.max(mediaPadding.bottom, viewInsets.bottom),
        ),
      ),
    );
    // A transient IME or an unusually small test/window viewport can consume
    // the entire safe area.  Returning an empty portal avoids constructing
    // non-normalized BoxConstraints while the field remains editable.
    if (safeRect.width <= 0 || safeRect.height <= 0) {
      return const SizedBox.shrink();
    }
    return CustomSingleChildLayout(
      delegate: _PromptOptionsLayoutDelegate(
        anchorRect: caretRect,
        safeRect: safeRect,
        maxWidth: math.min(420, layoutInfo.childSize.width),
      ),
      child: _buildOptionsSurface(
        math.min(420, layoutInfo.childSize.width),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final autocomplete = RawAutocomplete<PromptTagCandidate>(
      key: ValueKey('prompt-assisted-autocomplete-$_optionsRevision'),
      textEditingController: _controller,
      focusNode: _focusNode,
      // Keep keyboard navigation and dismissal semantics from Flutter's
      // RawAutocomplete while rendering the surface in our caret portal.
      optionsViewOpenDirection: OptionsViewOpenDirection.mostSpace,
      displayStringForOption: (candidate) => candidate.tag,
      optionsBuilder: (_) => _candidates,
      onSelected: _acceptCandidate,
      fieldViewBuilder: (context, controller, focusNode, _) =>
          _buildFieldView(context, controller, focusNode),
      // RawAutocomplete remains the keyboard/dismissal seam. Its internal
      // view is intentionally empty; the visible surface is the caret portal
      // below so a multiline cascade field does not anchor at its bottom.
      optionsViewBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _optionsPortalController,
      overlayChildBuilder: _buildOptionsOverlay,
      child: autocomplete,
    );
  }
}

class _PromptOptionsLayoutDelegate extends SingleChildLayoutDelegate {
  _PromptOptionsLayoutDelegate({
    required this.anchorRect,
    required this.safeRect,
    required this.maxWidth,
  });

  static const _gap = 4.0;
  static const _maxHeight = 280.0;
  static const _preferredWidth = 280.0;

  final Rect anchorRect;
  final Rect safeRect;
  final double maxWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final availableWidth = math.min(
      maxWidth,
      math.min(safeRect.width, constraints.maxWidth),
    );
    final maxHeight = math.min(
      _maxHeight,
      math.min(safeRect.height, constraints.maxHeight),
    );
    final minWidth = math.min(_preferredWidth, availableWidth);
    return BoxConstraints(
      minWidth: minWidth,
      maxWidth: availableWidth,
      maxHeight: maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final belowSpace = safeRect.bottom - (anchorRect.bottom + _gap);
    final aboveSpace = anchorRect.top - _gap - safeRect.top;
    final opensDown = belowSpace >= aboveSpace;
    final desiredY = opensDown
        ? anchorRect.bottom + _gap
        : anchorRect.top - childSize.height - _gap;
    final maxY = math.max(safeRect.top, safeRect.bottom - childSize.height);
    final y = desiredY.clamp(safeRect.top, maxY).toDouble();
    final maxX = math.max(safeRect.left, safeRect.right - childSize.width);
    final x = anchorRect.left.clamp(safeRect.left, maxX).toDouble();
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant _PromptOptionsLayoutDelegate oldDelegate) {
    return anchorRect != oldDelegate.anchorRect ||
        safeRect != oldDelegate.safeRect ||
        maxWidth != oldDelegate.maxWidth;
  }
}

class _PromptTextEditingController extends TextEditingController {
  _PromptTextEditingController({required super.text});

  void refresh() => notifyListeners();

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = super.buildTextSpan(
      context: context,
      style: style,
      withComposing: withComposing,
    );
    return PromptWeightSyntax.applyHighlights(base, text);
  }
}
