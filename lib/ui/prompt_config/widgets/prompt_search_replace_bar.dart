import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_text_highlighting.dart';

/// Mixin for [TextEditingController] subclasses that wish to render search-match
/// highlights inside their [buildTextSpan] override.
///
/// The mixin stores the match ranges and current-match index set by
/// [PromptSearchReplaceBar] and provides [splitSpanWithHighlights] to weave
/// highlight backgrounds into an existing [TextSpan] tree.
mixin SearchHighlightable on TextEditingController {
  List<TextRange> _searchMatches = const [];
  int _searchCurrentIndex = -1;

  List<TextRange> get searchMatches => _searchMatches;
  int get searchCurrentIndex => _searchCurrentIndex;

  void setSearchHighlights(List<TextRange> matches, int currentIndex) {
    _searchMatches = matches;
    _searchCurrentIndex = currentIndex;
    notifyListeners();
  }

  void clearSearchHighlights() {
    if (_searchMatches.isEmpty) return;
    _searchMatches = const [];
    _searchCurrentIndex = -1;
    notifyListeners();
  }

  /// Splits a flat [TextSpan] tree into sub-spans that carry search-highlight
  /// backgrounds.  Call this from [buildTextSpan] after building the base span.
  TextSpan applySearchHighlights(TextSpan base, BuildContext context) {
    if (_searchMatches.isEmpty) return base;
    final highlightBg =
        Theme.of(context).colorScheme.primaryContainer.withAlpha(140);
    final currentBg = Theme.of(context).colorScheme.primary.withAlpha(100);
    return applyPromptTextHighlights(
      base,
      [
        for (var index = 0; index < _searchMatches.length; index++)
          PromptTextHighlight(
            range: _searchMatches[index],
            style: TextStyle(
              backgroundColor:
                  index == _searchCurrentIndex ? currentBg : highlightBg,
            ),
          ),
      ],
    );
  }
}

/// A compact, theme-aware Search and Replace bar that attaches to any [TextEditingController].
class PromptSearchReplaceBar extends StatefulWidget {
  const PromptSearchReplaceBar({
    super.key,
    required this.controller,
    this.focusNode,
    this.visible = false,
    this.onClose,
    this.onChanged,
    this.initialReplaceMode = false,
    this.searchFieldKey,
    this.replaceFieldKey,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool visible;
  final VoidCallback? onClose;
  final ValueChanged<String>? onChanged;
  final bool initialReplaceMode;
  final Key? searchFieldKey;
  final Key? replaceFieldKey;

  @override
  State<PromptSearchReplaceBar> createState() => PromptSearchReplaceBarState();
}

class PromptSearchReplaceBarState extends State<PromptSearchReplaceBar> {
  late final TextEditingController searchController;
  late final TextEditingController replaceController;
  late final FocusNode searchFocusNode;
  late final FocusNode replaceFocusNode;

  bool _replaceMode = false;
  List<TextRange> _matches = const [];
  int _currentMatchIndex = -1;
  String _lastTargetText = '';

  List<TextRange> get matches => List.unmodifiable(_matches);
  int get currentMatchIndex => _currentMatchIndex;
  bool get replaceMode => _replaceMode;

  @override
  void initState() {
    super.initState();
    _replaceMode = widget.initialReplaceMode;
    searchController = TextEditingController();
    replaceController = TextEditingController();
    searchFocusNode = FocusNode(
      debugLabel: 'prompt-search-focus',
      onKeyEvent: _handleSearchKeyEvent,
    );
    replaceFocusNode = FocusNode(
      debugLabel: 'prompt-replace-focus',
      onKeyEvent: _handleReplaceKeyEvent,
    );

    widget.controller.addListener(_handleTargetControllerChanged);
    _lastTargetText = widget.controller.text;

    if (widget.visible) {
      _initSearchFromTarget();
    }
  }

  @override
  void didUpdateWidget(covariant PromptSearchReplaceBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTargetControllerChanged);
      widget.controller.addListener(_handleTargetControllerChanged);
      _lastTargetText = widget.controller.text;
      _updateMatches(preserveCurrentIndex: false);
    }
    if (!oldWidget.visible && widget.visible) {
      _initSearchFromTarget();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTargetControllerChanged);
    searchController.dispose();
    replaceController.dispose();
    searchFocusNode.dispose();
    replaceFocusNode.dispose();
    super.dispose();
  }

  void _initSearchFromTarget() {
    final selection = widget.controller.selection;
    if (selection.isValid && !selection.isCollapsed) {
      final selectedText = selection.textInside(widget.controller.text);
      if (selectedText.isNotEmpty && !selectedText.contains('\n')) {
        searchController.text = selectedText;
      }
    }
    _updateMatches(preserveCurrentIndex: false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      searchFocusNode.requestFocus();
      searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: searchController.text.length,
      );
    });
  }

  void _handleTargetControllerChanged() {
    final currentText = widget.controller.text;
    if (currentText != _lastTargetText) {
      _lastTargetText = currentText;
      if (widget.visible && searchController.text.isNotEmpty) {
        _updateMatches(preserveCurrentIndex: true);
      }
    }
  }

  KeyEventResult _handleSearchKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      close();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        findPrevious();
      } else {
        findNext();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleReplaceKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      close();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      replaceCurrent();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _updateMatches(
      {bool preserveCurrentIndex = false, int? preferredOffset}) {
    final query = searchController.text;
    if (query.isEmpty) {
      setState(() {
        _matches = const [];
        _currentMatchIndex = -1;
      });
      _clearHighlights();
      return;
    }

    final text = widget.controller.text;
    final lowerText = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final newMatches = <TextRange>[];

    var start = 0;
    while (start < lowerText.length) {
      final index = lowerText.indexOf(lowerQuery, start);
      if (index == -1) break;
      newMatches.add(TextRange(start: index, end: index + query.length));
      start = index + math.max(1, query.length);
    }

    if (newMatches.isEmpty) {
      setState(() {
        _matches = const [];
        _currentMatchIndex = -1;
      });
      _clearHighlights();
      return;
    }

    var newIndex = 0;
    if (preferredOffset != null) {
      for (var i = 0; i < newMatches.length; i++) {
        if (newMatches[i].start >= preferredOffset) {
          newIndex = i;
          break;
        }
      }
    } else if (preserveCurrentIndex &&
        _currentMatchIndex >= 0 &&
        _currentMatchIndex < _matches.length) {
      final previousMatch = _matches[_currentMatchIndex];
      var closestDist = (newMatches[0].start - previousMatch.start).abs();
      for (var i = 1; i < newMatches.length; i++) {
        final dist = (newMatches[i].start - previousMatch.start).abs();
        if (dist < closestDist) {
          closestDist = dist;
          newIndex = i;
        }
      }
    } else {
      final selStart = widget.controller.selection.start;
      if (selStart >= 0) {
        for (var i = 0; i < newMatches.length; i++) {
          if (newMatches[i].start >= selStart) {
            newIndex = i;
            break;
          }
        }
      }
    }

    setState(() {
      _matches = newMatches;
      _currentMatchIndex = newIndex.clamp(0, newMatches.length - 1);
    });

    _pushHighlights();
    _highlightMatch(_currentMatchIndex);
  }

  /// Push current match data to the controller so it can render highlights
  /// in its [buildTextSpan].
  void _pushHighlights() {
    final c = widget.controller;
    if (c is SearchHighlightable) {
      c.setSearchHighlights(List.unmodifiable(_matches), _currentMatchIndex);
    }
  }

  void _clearHighlights() {
    final c = widget.controller;
    if (c is SearchHighlightable) {
      c.clearSearchHighlights();
    }
  }

  void _highlightMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final match = _matches[index];
    widget.controller.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
  }

  void findNext() {
    if (_matches.isEmpty) return;
    setState(() {
      _currentMatchIndex = (_currentMatchIndex + 1) % _matches.length;
    });
    _pushHighlights();
    _highlightMatch(_currentMatchIndex);
  }

  void findPrevious() {
    if (_matches.isEmpty) return;
    setState(() {
      _currentMatchIndex =
          (_currentMatchIndex - 1 + _matches.length) % _matches.length;
    });
    _pushHighlights();
    _highlightMatch(_currentMatchIndex);
  }

  void toggleReplaceMode() {
    setState(() {
      _replaceMode = !_replaceMode;
    });
    if (_replaceMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          replaceFocusNode.requestFocus();
          replaceController.selection = TextSelection(
            baseOffset: 0,
            extentOffset: replaceController.text.length,
          );
        }
      });
    }
  }

  void replaceCurrent() {
    if (_matches.isEmpty ||
        _currentMatchIndex < 0 ||
        _currentMatchIndex >= _matches.length) {
      return;
    }
    final query = searchController.text;
    final match = _matches[_currentMatchIndex];
    final currentText = widget.controller.text;

    if (match.start < 0 ||
        match.end > currentText.length ||
        currentText.substring(match.start, match.end).toLowerCase() !=
            query.toLowerCase()) {
      _updateMatches();
      return;
    }

    final replaceWith = replaceController.text;
    final newText =
        currentText.replaceRange(match.start, match.end, replaceWith);
    final nextOffset = match.start + replaceWith.length;

    _lastTargetText = newText;
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: nextOffset.clamp(0, newText.length),
      ),
    );
    widget.onChanged?.call(newText);

    _updateMatches(preferredOffset: nextOffset);
  }

  void replaceAll() {
    final query = searchController.text;
    if (query.isEmpty || _matches.isEmpty) return;

    final replaceWith = replaceController.text;

    // Apply replacements in reverse order one by one on the controller
    // so document controllers (like _PromptDocumentController) remap each replacement cleanly.
    for (var i = _matches.length - 1; i >= 0; i--) {
      final m = _matches[i];
      final currentText = widget.controller.text;
      if (m.start >= 0 &&
          m.end <= currentText.length &&
          currentText.substring(m.start, m.end).toLowerCase() ==
              query.toLowerCase()) {
        final newText = currentText.replaceRange(m.start, m.end, replaceWith);
        widget.controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
            offset: m.start + replaceWith.length,
          ),
        );
      }
    }

    _lastTargetText = widget.controller.text;
    widget.controller.selection = TextSelection.collapsed(
      offset: widget.controller.text.length,
    );
    widget.onChanged?.call(widget.controller.text);

    _updateMatches();
  }

  void close() {
    _clearHighlights();
    widget.onClose?.call();
    widget.focusNode?.requestFocus();
  }

  String _tr(BuildContext context, String key, {required String fallback}) {
    try {
      final val = context.tr(key);
      return (val.isEmpty || val == key) ? fallback : val;
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) {
      return const SizedBox.shrink(
          key: Key('prompt-search-replace-bar-hidden'));
    }

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final matchCountText = _matches.isEmpty
        ? (searchController.text.isEmpty
            ? '0/0'
            : _tr(context, 'no_matches', fallback: '0/0'))
        : '${_currentMatchIndex + 1}/${_matches.length}';

    return Container(
      key: const Key('prompt-search-replace-bar'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh.withAlpha(240),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withAlpha(140),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(18),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.search,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  key:
                      widget.searchFieldKey ?? const Key('prompt-search-field'),
                  controller: searchController,
                  focusNode: searchFocusNode,
                  style: theme.textTheme.bodyMedium,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: InputDecoration(
                    hintText: _tr(context, 'search', fallback: 'Search'),
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant.withAlpha(160),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => _updateMatches(),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                matchCountText,
                key: const Key('prompt-search-match-count'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _matches.isEmpty && searchController.text.isNotEmpty
                      ? colorScheme.error
                      : colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const Key('prompt-search-prev'),
                icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                splashRadius: 14,
                tooltip:
                    _tr(context, 'previous_match', fallback: 'Previous match'),
                onPressed: _matches.isEmpty ? null : findPrevious,
              ),
              IconButton(
                key: const Key('prompt-search-next'),
                icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                splashRadius: 14,
                tooltip: _tr(context, 'next_match', fallback: 'Next match'),
                onPressed: _matches.isEmpty ? null : findNext,
              ),
              IconButton(
                key: const Key('prompt-search-toggle-replace'),
                icon: Icon(
                  Icons.find_replace,
                  size: 18,
                  color: _replaceMode ? colorScheme.primary : null,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                splashRadius: 14,
                tooltip:
                    _tr(context, 'toggle_replace', fallback: 'Toggle replace'),
                onPressed: toggleReplaceMode,
              ),
              IconButton(
                key: const Key('prompt-search-close'),
                icon: const Icon(Icons.close, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                splashRadius: 14,
                tooltip: _tr(context, 'close', fallback: 'Close'),
                onPressed: close,
              ),
            ],
          ),
          if (_replaceMode) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.swap_horiz,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    key: widget.replaceFieldKey ??
                        const Key('prompt-replace-field'),
                    controller: replaceController,
                    focusNode: replaceFocusNode,
                    style: theme.textTheme.bodyMedium,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      hintText: _tr(context, 'replace', fallback: 'Replace'),
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant.withAlpha(160),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  key: const Key('prompt-search-replace-btn'),
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(40, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: _matches.isEmpty ? null : replaceCurrent,
                  child: Text(_tr(context, 'replace', fallback: 'Replace')),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  key: const Key('prompt-search-replace-all-btn'),
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    minimumSize: const Size(40, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: _matches.isEmpty ? null : replaceAll,
                  child: Text(
                    _tr(context, 'replace_all', fallback: 'Replace All'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
