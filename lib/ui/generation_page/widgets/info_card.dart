import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/widgets/fullscreen_image_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generated_image_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart';
import 'package:nai_casrand/ui/generation_page/widgets/prompt_token_usage.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_area.dart';
import 'package:nai_casrand/ui/prompt_assistance/prompt_text_highlighting.dart';
import 'package:nai_casrand/ui/prompt_config/widgets/prompt_search_replace_bar.dart';
import 'package:flutter_command/flutter_command.dart';

class InfoCard extends StatelessWidget {
  final Command<void, InfoCardContent> command;
  final VoidCallback? onOpenDetail;

  CommandStatus get commandStatus => GetIt.I();
  Settings get settings => GetIt.I<PayloadConfig>().settings;

  const InfoCard({super.key, required this.command, this.onOpenDetail});

  @override
  Widget build(BuildContext context) {
    final cardBody = ListenableBuilder(
      listenable:
          Listenable.merge([command, command.isExecuting, commandStatus]),
      builder: (context, child) {
        final waiting = commandStatus.waitingFor(command);
        final unknown = commandStatus.outcomeUnknownFor(command);
        if ((waiting != null || unknown != null) &&
            command.value.imageBytes == null) {
          return GenerationCardStatusView(
            waiting: waiting,
            unknown: unknown,
            tokenLabel: commandStatus.tokenLabelFor(command),
          );
        }
        if (commandStatus.isExecuting(command) &&
            command.value.imageBytes == null) {
          // Loading
          return ListTile(
            leading: const CircularProgressIndicator(),
            subtitle: commandStatus.tokenLabelFor(command) == null
                ? null
                : Text(commandStatus.tokenLabelFor(command)!),
            title: Text(commandStatus.requestingLabel(
              command,
              configuredTotal: settings.generationCount,
            )),
          );
        } else {
          // Result
          return _buildCardContentBody(context, command.value);
        }
      },
    );

    return Card(
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: onOpenDetail ?? () => _showDetailedInfoDialog(context),
        child: cardBody,
      ),
    );
  }

  void _showDetailedInfoDialog(BuildContext context) {
    if (commandStatus.isExecuting(command)) return;
    final content = command.value;

    // 跳转到新页面
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InfoDetailPage(content: content),
      ),
    );
  }

  Widget buildInfoTile(String title, String content, BuildContext context) {
    return ListTile(
      titleAlignment: ListTileTitleAlignment.titleHeight,
      title: Text(title),
      subtitle: Text(content),
      trailing: IconButton(
          onPressed: () {
            _copyContent(content, context);
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.copy)),
    );
  }

  void _copyContent(String content, BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!context.mounted) return;
    showInfoBar(context, '${tr('info_export_to_clipboard')}${tr('succeed')}');
  }

  Widget _buildCardContentBody(BuildContext context, InfoCardContent content) {
    return !content.hasImage
        ? //Without image
        Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(content.title),
                subtitle: content.tokenLabel == null
                    ? null
                    : Text(content.tokenLabel!),
              ),
              ListTile(
                subtitle: Text(
                  content.info,
                  maxLines: 20,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            ],
          )
        : // With image
        Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_outlined),
                title: Text(
                  content.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: _anlasSubtitle(content),
              ),
              GeneratedImageView(
                content: content,
                child: buildInfoCardImage(content),
              ),
            ],
          );
  }

  Widget? _anlasSubtitle(InfoCardContent content) {
    final parts = <String>[];
    if (content.tokenLabel != null) parts.add(content.tokenLabel!);
    if (content.anlasCost != null) {
      if (content.anlasCostIsEstimated) {
        final key =
            content.anlasRemaining != null && content.batchAnlasCost == null
                ? 'anlas_estimated_with_remaining'
                : 'anlas_estimated_info';
        parts.add(tr(key, namedArgs: {
          'cost': content.anlasCost.toString(),
          'remaining': content.anlasRemaining?.toString() ?? '?',
        }));
      } else {
        parts.add(tr('anlas_info', namedArgs: {
          'cost': content.anlasCost.toString(),
          'remaining': content.anlasRemaining?.toString() ?? '?',
        }));
      }
    } else if (content.anlasRemaining != null) {
      parts.add(tr('anlas_remaining_only', namedArgs: {
        'remaining': content.anlasRemaining.toString(),
      }));
    }
    if (content.batchAnlasCost != null) {
      parts.add(tr('anlas_batch_info', namedArgs: {
        'cost': content.batchAnlasCost.toString(),
        'remaining': content.anlasRemaining?.toString() ?? '?',
      }));
    }
    if (parts.isEmpty) return null;
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A lightweight status view shared by both card layouts. Its timer lives only
/// while a cooldown is visible, never in the long-lived generation model.
class GenerationCardStatusView extends StatefulWidget {
  const GenerationCardStatusView({
    super.key,
    this.waiting,
    this.unknown,
    this.tokenLabel,
  });

  final GenerationCardWaiting? waiting;
  final GenerationCardOutcomeUnknown? unknown;
  final String? tokenLabel;

  @override
  State<GenerationCardStatusView> createState() =>
      _GenerationCardStatusViewState();
}

class _GenerationCardStatusViewState extends State<GenerationCardStatusView> {
  Timer? _timer;
  int _seconds = 0;

  int _wallClockSeconds() => max(
      0,
      ((widget.waiting?.retryAt.difference(DateTime.now()).inMilliseconds ??
                  0) /
              1000)
          .ceil());

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void didUpdateWidget(covariant GenerationCardStatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.waiting?.retryAt != widget.waiting?.retryAt) {
      _startCountdown();
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    _seconds = _wallClockSeconds();
    if (_seconds == 0) return;
    final initialSeconds = _seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // Timer ticks also account for delayed callbacks; wall time catches an
      // OS clock advancing. Neither makes a visible countdown run backwards.
      setState(() {
        _seconds =
            max(0, min(initialSeconds - timer.tick, _wallClockSeconds()));
      });
      if (_seconds == 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unknown = widget.unknown;
    final title = unknown != null
        ? tr(switch (unknown.phase) {
            GenerationOutcomePhase.receiving => 'generation_response_receiving',
            GenerationOutcomePhase.disconnected =>
              'generation_response_disconnected',
            GenerationOutcomePhase.unknown => 'generation_outcome_unknown',
          })
        : tr('generation_retry_waiting', namedArgs: {
            'message': widget.waiting?.message ?? '',
            'seconds': '$_seconds',
          });
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(switch (unknown?.phase) {
              GenerationOutcomePhase.receiving => Icons.downloading,
              GenerationOutcomePhase.disconnected => Icons.wifi_off,
              GenerationOutcomePhase.unknown => Icons.help_outline,
              null => Icons.hourglass_empty,
            }),
            const SizedBox(width: 8),
            Expanded(child: Text(title)),
            if (unknown?.message != null &&
                unknown?.phase != GenerationOutcomePhase.unknown)
              IconButton(
                tooltip: tr('generation_error_details'),
                icon: const Icon(Icons.info_outline, size: 20),
                onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                          title: Text(tr('generation_error_details')),
                          content: SingleChildScrollView(
                              child: SelectableText(unknown!.message!)),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('OK'))
                          ],
                        )),
              ),
          ]),
          if (widget.tokenLabel case final label?) ...[
            const SizedBox(height: 6),
            Text(label),
          ],
          if (unknown != null) ...[
            const SizedBox(height: 6),
            Text(tr(switch (unknown.phase) {
              GenerationOutcomePhase.receiving =>
                'generation_response_receiving_detail',
              GenerationOutcomePhase.disconnected =>
                'generation_response_disconnected_detail',
              GenerationOutcomePhase.unknown =>
                'generation_outcome_unknown_detail',
            })),
            if (unknown.onRetry != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: unknown.onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(tr('generation_regenerate_original')),
              ),
            ],
            if (unknown.message != null &&
                unknown.phase == GenerationOutcomePhase.unknown) ...[
              const SizedBox(height: 6),
              Text(unknown.message!),
            ],
          ],
        ],
      ),
    );
  }
}

Widget buildInfoCardImage(
  InfoCardContent content, {
  BoxFit fit = BoxFit.contain,
  FilterQuality filterQuality = FilterQuality.medium,
}) {
  final filePath = content.currentImageFile?.path;
  if (filePath != null && filePath.isNotEmpty) {
    return Image.file(
      File(filePath),
      fit: fit,
      filterQuality: filterQuality,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        if (content.imageBytes != null && content.imageBytes!.isNotEmpty) {
          return Image.memory(
            content.imageBytes!,
            fit: fit,
            filterQuality: filterQuality,
            gaplessPlayback: true,
          );
        }
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
          ),
        );
      },
    );
  } else if (content.imageBytes != null && content.imageBytes!.isNotEmpty) {
    return Image.memory(
      content.imageBytes!,
      fit: fit,
      filterQuality: filterQuality,
      gaplessPlayback: true,
    );
  }
  return const SizedBox.shrink();
}

/// Width at which the detail page switches from a stacked layout to image
/// beside prompt, matching the navigation shell's own breakpoint.
const double detailWideLayoutBreakpoint = 640;

/// additionalInfo keys surfaced as compact parameter chips, in display order.
/// Everything else stays available under the "all parameters" expander.
const List<(String, String)> _detailParamKeys = [
  ('seed', 'seed'),
  ('steps', 'steps'),
  ('sampler', 'sampler'),
  ('scale', 'scale'),
  ('cfg_rescale', 'cfg_rescale'),
  ('noise_schedule', 'noise_schedule'),
  ('model', 'model'),
  ('action', 'action'),
];

class InfoDetailPage extends StatefulWidget {
  final List<InfoCardContent> contents;
  final PromptTokenCounter? tokenCounter;
  final int initialIndex;
  final ValueChanged<int>? onIndexChanged;

  /// Number of results per row in the grid the gallery was opened from.
  /// When set, ↑/↓ jump a whole row; null leaves ↑/↓ unbound (for example
  /// the waterfall layout, whose items do not sit in fixed rows).
  final int? rowStride;

  InfoDetailPage(
      {super.key, required InfoCardContent content, this.tokenCounter})
      : contents = [content],
        initialIndex = 0,
        onIndexChanged = null,
        rowStride = null;

  const InfoDetailPage.gallery({
    super.key,
    required this.contents,
    this.tokenCounter,
    required this.initialIndex,
    this.onIndexChanged,
    this.rowStride,
  });

  @override
  State<InfoDetailPage> createState() => _InfoDetailPageState();
}

/// Read-only search target for the detail page: the prompt cards' texts
/// joined by [_InfoDetailPageState._segmentSeparator]. The search bar writes
/// its matches here and each card renders the ones inside its own segment.
class _DetailSearchController extends TextEditingController
    with SearchHighlightable {}

class _InfoDetailPageState extends State<InfoDetailPage> {
  /// Joins the searchable cards. Typed queries cannot contain it, so a match
  /// never spans two cards.
  static const String _segmentSeparator = '\u0000';

  final FocusNode _focusNode = FocusNode();
  late int _currentIndex;

  final _DetailSearchController _searchController = _DetailSearchController();
  final GlobalKey<PromptSearchReplaceBarState> _searchBarKey = GlobalKey();
  final Map<int, GlobalKey> _segmentKeys = {};
  bool _searchVisible = false;
  List<int> _segmentStarts = const [];
  List<TextRange>? _revealedMatches;
  int _revealedIndex = -1;

  InfoCardContent get content => widget.contents[_currentIndex];
  bool get _hasPrevious => _currentIndex > 0;
  bool get _hasNext => _currentIndex + 1 < widget.contents.length;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.contents.length - 1);
    _syncSearchText();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void didUpdateWidget(covariant InfoDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.contents, widget.contents)) return;
    _currentIndex = _preserveCurrentIndex(
      oldContents: oldWidget.contents,
      newContents: widget.contents,
    );
    _syncSearchText();
  }

  /// Prompt texts shown as cards, in display order: prompt blocks, final
  /// prompt, negative prompt. Indices are the cards' search segments.
  List<String> _searchSegments(InfoCardContent content) {
    final input = content.additionalInfo['input'];
    final negative = content.additionalInfo['negative_prompt'];
    return [
      if (content.info.isNotEmpty) content.info,
      if (input is String) input,
      if (negative is String) negative,
    ];
  }

  void _syncSearchText() {
    final segments = _searchSegments(content);
    final starts = <int>[];
    var offset = 0;
    for (final segment in segments) {
      starts.add(offset);
      offset += segment.length + _segmentSeparator.length;
    }
    _segmentStarts = starts;
    final text = segments.join(_segmentSeparator);
    if (_searchController.text != text) {
      _searchController.value = TextEditingValue(text: text);
      // A different result's texts: search them again from the top.
      _searchBarKey.currentState?.restartSearch();
    }
  }

  /// Matches inside one card, in card-local offsets, plus which of them (if
  /// any) is the current match.
  (List<TextRange>, int) _segmentMatches(int segment, int length) {
    final matches = _searchController.searchMatches;
    if (!_searchVisible ||
        matches.isEmpty ||
        segment >= _segmentStarts.length) {
      return (const [], -1);
    }
    final start = _segmentStarts[segment];
    final end = start + length;
    final local = <TextRange>[];
    var current = -1;
    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      if (match.start < start || match.end > end) continue;
      if (i == _searchController.searchCurrentIndex) current = local.length;
      local.add(TextRange(start: match.start - start, end: match.end - start));
    }
    return (local, current);
  }

  void _handleSearchChanged() {
    final matches = _searchController.searchMatches;
    final index = _searchController.searchCurrentIndex;
    if (identical(matches, _revealedMatches) && index == _revealedIndex) {
      return;
    }
    _revealedMatches = matches;
    _revealedIndex = index;
    if (index < 0 || index >= matches.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealCurrentMatch();
    });
  }

  /// Scrolls the info panel so the current match's line is visible.
  void _revealCurrentMatch() {
    final matches = _searchController.searchMatches;
    final index = _searchController.searchCurrentIndex;
    if (index < 0 || index >= matches.length) return;
    final match = matches[index];
    var segment = -1;
    for (var i = _segmentStarts.length - 1; i >= 0; i--) {
      if (match.start >= _segmentStarts[i]) {
        segment = i;
        break;
      }
    }
    if (segment < 0) return;
    final targetContext = _segmentKeys[segment]?.currentContext;
    final box = targetContext?.findRenderObject();
    if (targetContext == null || box is! RenderBox || !box.hasSize) return;
    final segments = _searchSegments(content);
    if (segment >= segments.length) return;
    final localStart = match.start - _segmentStarts[segment];
    final localEnd = match.end - _segmentStarts[segment];
    final painter = TextPainter(
      text: TextSpan(
        text: segments[segment],
        style: DefaultTextStyle.of(targetContext)
            .style
            .merge(Theme.of(targetContext).textTheme.bodyMedium),
      ),
      textDirection: Directionality.of(targetContext),
      textScaler: MediaQuery.textScalerOf(targetContext),
    )..layout(maxWidth: box.size.width);
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: localStart, extentOffset: localEnd),
    );
    painter.dispose();
    final rect = boxes.isEmpty
        ? Offset.zero & box.size
        : boxes.first.toRect().inflate(32);
    box.showOnScreen(
      rect: rect,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _openSearch() {
    if (_searchVisible) {
      _searchBarKey.currentState?.searchFocusNode.requestFocus();
      return;
    }
    setState(() => _searchVisible = true);
  }

  void _closeSearch() {
    if (!_searchVisible) return;
    setState(() => _searchVisible = false);
    _searchController.clearSearchHighlights();
    _focusNode.requestFocus();
  }

  /// Keeps the gallery on the result the user is already viewing when the
  /// underlying list changes (for example new generations are prepended while
  /// this page is open). Contents are immutable, so identity handles the
  /// normal case; title matching also survives balance refreshes that replace
  /// the viewed [InfoCardContent] with a `copyWith` sibling.
  int _preserveCurrentIndex({
    required List<InfoCardContent> oldContents,
    required List<InfoCardContent> newContents,
  }) {
    if (oldContents.isEmpty || newContents.isEmpty) return 0;
    final oldIndex = _currentIndex.clamp(0, oldContents.length - 1);
    final current = oldContents[oldIndex];
    var nextIndex = newContents.indexOf(current);
    if (nextIndex < 0) {
      nextIndex = newContents.indexWhere(
        (content) => content.title == current.title,
      );
    }
    if (nextIndex < 0) {
      // The viewed result left the list (for example it fell off the
      // 200-item history). Stay at the closest surviving position instead
      // of jumping back to the newest result.
      nextIndex = oldIndex;
    }
    return nextIndex.clamp(0, newContents.length - 1);
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hardware = HardwareKeyboard.instance;
    if ((hardware.isMetaPressed || hardware.isControlPressed) &&
        !hardware.isShiftPressed &&
        !hardware.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      _openSearch();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space && content.hasImage) {
      openFullscreenImage(context, content);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _changeIndex(_currentIndex - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _changeIndex(_currentIndex + 1);
      return KeyEventResult.handled;
    }
    final rowStride = widget.rowStride;
    if (rowStride != null && rowStride > 0) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _changeIndex(_currentIndex - rowStride);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _changeIndex(_currentIndex + rowStride);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // An open search bar closes first; the next Esc leaves the page.
      if (_searchVisible) {
        _closeSearch();
      } else {
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _changeIndex(int index) {
    if (index < 0 ||
        index >= widget.contents.length ||
        index == _currentIndex) {
      return;
    }
    setState(() {
      _currentIndex = index;
      _syncSearchText();
    });
    widget.onIndexChanged?.call(index);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final showShortcutHint = MediaQuery.sizeOf(context).width >= 720;
    return ImageImportArea(
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Expanded(
                child: Text(
                  content.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.contents.length > 1)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Center(
                    child: Text(
                      '${_currentIndex + 1} / ${widget.contents.length}',
                      key: const Key('detail-gallery-position'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              if (content.hasImage && showShortcutHint)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      tr(widget.rowStride != null
                          ? 'detail_shortcut_hint_grid'
                          : 'detail_shortcut_hint'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Outside the page's key handler, so arrow keys and Esc typed in
            // the search field never switch images or leave the page.
            Padding(
              padding: EdgeInsets.fromLTRB(12, _searchVisible ? 8 : 0, 12, 0),
              child: PromptSearchReplaceBar(
                key: _searchBarKey,
                controller: _searchController,
                focusNode: _focusNode,
                visible: _searchVisible,
                allowReplace: false,
                searchFieldKey: const Key('detail-search-field'),
                onClose: _closeSearch,
              ),
            ),
            Expanded(
              child: Focus(
                focusNode: _focusNode,
                autofocus: true,
                onKeyEvent: _handleKey,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide =
                        constraints.maxWidth >= detailWideLayoutBreakpoint &&
                            content.hasImage;
                    return wide
                        ? _buildWideLayout(context)
                        : _buildStackedLayout(context);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Image on the left, prompt and parameters on the right, so a tall image
  /// never pushes the prompt off-screen.
  Widget _buildWideLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Expanded(child: _buildImagePane(context)),
                const SizedBox(height: 12),
                ResultActionBar(content: content),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 4,
          // Not a lazy ListView: search must be able to scroll to a match in
          // any card, so every card stays laid out.
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _buildInfoPanel(context),
            ),
          ),
        ),
      ],
    );
  }

  /// Single-column layout for narrow windows and phones.
  Widget _buildStackedLayout(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (content.hasImage) ...[
            // Fixed-height stage so the layout does not jump while the image
            // decodes; the dark surface absorbs the letterboxing.
            SizedBox(height: 420, child: _buildImagePane(context)),
            const SizedBox(height: 12),
            ResultActionBar(content: content),
            const SizedBox(height: 4),
          ],
          ..._buildInfoPanel(context),
        ],
      ),
    );
  }

  /// The image on a dark rounded stage, like the official result viewer.
  Widget _buildImagePane(BuildContext context) {
    if (!content.hasImage) return const SizedBox.shrink();
    return GestureDetector(
      key: const Key('detail-gallery-swipe-target'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -120) {
          _changeIndex(_currentIndex + 1);
        } else if (velocity > 120) {
          _changeIndex(_currentIndex - 1);
        }
      },
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GeneratedImageView(
              key: ValueKey('detail-image-$_currentIndex'),
              content: content,
              child: GestureDetector(
                key: const Key('detail-image-zoom-target'),
                onTap: () => openFullscreenImage(context, content),
                child: buildInfoCardImage(
                  content,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
            if (_hasPrevious)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    key: const Key('detail-gallery-previous'),
                    tooltip: tr('detail_previous_image'),
                    onPressed: () => _changeIndex(_currentIndex - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                ),
              ),
            if (_hasNext)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton.filledTonal(
                    key: const Key('detail-gallery-next'),
                    tooltip: tr('detail_next_image'),
                    onPressed: () => _changeIndex(_currentIndex + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildInfoPanel(BuildContext context) {
    final additional = content.additionalInfo;
    final knownKeys = <String>{
      for (final (key, _) in _detailParamKeys) key,
      'input',
      'negative_prompt',
      'width',
      'height',
    };
    final remaining = [
      for (final entry in additional.entries)
        if (!knownKeys.contains(entry.key)) entry,
    ];
    final input = additional['input'];
    final negative = additional['negative_prompt'];
    // Search segment indices, matching [_searchSegments].
    var nextSegment = 0;
    final blocksSegment = content.info.isNotEmpty ? nextSegment++ : null;
    final inputSegment = input is String ? nextSegment++ : null;
    final negativeSegment = negative is String ? nextSegment++ : null;

    return [
      if (content.info.isNotEmpty)
        _buildTextCard(context, tr('detail_prompt_blocks'), content.info,
            searchSegment: blocksSegment),
      PromptTokenUsage(
        metadata: additional,
        counter: widget.tokenCounter,
        builder: (positiveBar, negativeBar) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (input is String)
              _buildTextCard(context, tr('detail_prompt_final'), input,
                  footer: positiveBar, searchSegment: inputSegment),
            if (negative is String)
              _buildTextCard(context, tr('detail_negative'), negative,
                  footer: negativeBar, searchSegment: negativeSegment),
          ],
        ),
      ),
      _buildParamsCard(context),
      if (remaining.isNotEmpty)
        Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const Key('detail-all-params'),
            leading: const Icon(Icons.data_object),
            title: Text(tr('detail_all_params')),
            children: [
              for (final entry in remaining)
                ListTile(
                  dense: true,
                  titleAlignment: ListTileTitleAlignment.top,
                  title: Text(entry.key),
                  subtitle: SelectableText(entry.value.toString()),
                  trailing: IconButton(
                    onPressed: () =>
                        _copyContent(entry.value.toString(), context),
                    tooltip: tr('copy_to_clipboard'),
                    icon: const Icon(Icons.copy, size: 18),
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  /// A prompt-style card: selectable body text with a copy affordance.
  Widget _buildTextCard(BuildContext context, String title, String body,
      {Widget? footer, int? searchSegment}) {
    return Card(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 8, footer == null ? 12 : 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  onPressed: () => _copyContent(body, context),
                  tooltip: tr('copy_to_clipboard'),
                  icon: const Icon(Icons.copy, size: 18),
                ),
              ],
            ),
            if (searchSegment == null)
              SelectableText(
                body,
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              _buildSearchableBody(context, body, searchSegment),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: footer,
              ),
          ],
        ),
      ),
    );
  }

  /// Card body that renders the search matches falling inside its segment.
  Widget _buildSearchableBody(BuildContext context, String body, int segment) {
    final key = _segmentKeys.putIfAbsent(segment, GlobalKey.new);
    return ListenableBuilder(
      listenable: _searchController,
      builder: (context, _) {
        final style = Theme.of(context).textTheme.bodyMedium;
        final (matches, current) = _segmentMatches(segment, body.length);
        if (matches.isEmpty) {
          return SelectableText(body, key: key, style: style);
        }
        final colors = Theme.of(context).colorScheme;
        final highlightBg = colors.primaryContainer.withAlpha(140);
        final currentBg = colors.primary.withAlpha(100);
        final span = applyPromptTextHighlights(
          TextSpan(text: body),
          [
            for (var i = 0; i < matches.length; i++)
              PromptTextHighlight(
                range: matches[i],
                style: TextStyle(
                  backgroundColor: i == current ? currentBg : highlightBg,
                ),
              ),
          ],
        );
        return SelectableText.rich(span, key: key, style: style);
      },
    );
  }

  /// Key parameters as label/value chips, with size and Anlas merged in.
  Widget _buildParamsCard(BuildContext context) {
    final additional = content.additionalInfo;
    final chips = <Widget>[];

    final width = additional['width'];
    final height = additional['height'];
    if (width != null && height != null) {
      chips.add(_paramChip(context, tr('detail_size'), '$width × $height'));
    }
    for (final (key, label) in _detailParamKeys) {
      final value = additional[key];
      if (value == null) continue;
      final text = value.toString();
      if (text.isEmpty) continue;
      chips.add(_paramChip(context, label, text));
    }
    if (content.tokenLabel != null) {
      chips.add(_paramChip(context, tr('api_token'), content.tokenLabel!));
    }
    if (content.anlasCost != null) {
      chips.add(_paramChip(
        context,
        tr(content.anlasCostIsEstimated
            ? 'anlas_estimated_cost'
            : 'anlas_cost'),
        content.anlasCost.toString(),
      ));
    }
    if (content.anlasRemaining != null) {
      chips.add(_paramChip(
          context, tr('anlas_remaining'), content.anlasRemaining.toString()));
    }
    if (content.batchAnlasCost != null) {
      chips.add(_paramChip(
        context,
        tr('anlas_batch_cost'),
        content.batchAnlasCost.toString(),
      ));
    }
    final showOpusUsage =
        content.opusUsage != null || content.opusUsageSettling;
    if (chips.isEmpty && !showOpusUsage) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('detail_parameters'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
            if (showOpusUsage) ...[
              const SizedBox(height: 14),
              _buildOpusUsageBar(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOpusUsageBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final usage = content.opusUsage;
    final percent = usage?.visiblePercent;
    final percentLabel = percent == null ? '—' : '${percent.round()}%';
    // Flutter's progress indicator accepts only a 0-1 value. Keep the
    // numeric label above 100% while rendering boosted usage as a full bar.
    final progressValue =
        percent == null ? null : (percent / 100).clamp(0, 1).toDouble();
    final stateLabel = content.opusUsageIsEstimated
        ? tr('opus_usage_estimated')
        : tr('opus_usage_actual');
    final settlingLabel =
        content.opusUsageSettling ? ' · ${tr('opus_usage_settling')}' : '';
    return Container(
      key: const Key('opus-usage-limit-bar'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('opus_generation_usage_limit'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Text(
                '$stateLabel · $percentLabel$settlingLabel',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.outline,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progressValue,
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
          ),
          if (usage != null && usage.refillPercentPerHour > 0) ...[
            const SizedBox(height: 6),
            Text(
              tr(
                'opus_usage_refill_rate',
                namedArgs: {
                  'rate': usage.refillPercentPerHour.toStringAsFixed(1),
                },
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.outline,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _paramChip(BuildContext context, String label, String value) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _copyContent(value, context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.outline,
                  ),
            ),
            Text(value, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  void _copyContent(String body, BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: body));
    if (!context.mounted) return;
    showInfoBar(context, '${tr('info_export_to_clipboard')}${tr('succeed')}');
  }
}
