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
      listenable: command.isExecuting,
      builder: (context, child) {
        if (command.isExecuting.value && command.value.imageBytes == null) {
          // Loading
          return ListTile(
            leading: const CircularProgressIndicator(),
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
    if (command.isExecuting.value) return;
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
    return content.imageBytes == null
        ? //Without image
        Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(content.title),
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
                child: Image.memory(
                  fit: BoxFit.contain,
                  content.imageBytes!,
                  filterQuality: FilterQuality.medium,
                ),
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
  final int initialIndex;
  final ValueChanged<int>? onIndexChanged;

  InfoDetailPage({super.key, required InfoCardContent content})
      : contents = [content],
        initialIndex = 0,
        onIndexChanged = null;

  const InfoDetailPage.gallery({
    super.key,
    required this.contents,
    required this.initialIndex,
    this.onIndexChanged,
  });

  @override
  State<InfoDetailPage> createState() => _InfoDetailPageState();
}

class _InfoDetailPageState extends State<InfoDetailPage> {
  final FocusNode _focusNode = FocusNode();
  late int _currentIndex;

  InfoCardContent get content => widget.contents[_currentIndex];
  bool get _hasPrevious => _currentIndex > 0;
  bool get _hasNext => _currentIndex + 1 < widget.contents.length;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.contents.length - 1);
  }

  @override
  void didUpdateWidget(covariant InfoDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.contents, widget.contents)) return;
    _currentIndex = _preserveCurrentIndex(
      oldContents: oldWidget.contents,
      newContents: widget.contents,
    );
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
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space &&
        content.imageBytes != null) {
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
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
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
    setState(() => _currentIndex = index);
    widget.onIndexChanged?.call(index);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final showShortcutHint = MediaQuery.sizeOf(context).width >= 720;
    return Scaffold(
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
            if (content.imageBytes != null && showShortcutHint)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    tr('detail_shortcut_hint'),
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
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= detailWideLayoutBreakpoint &&
                content.imageBytes != null;
            return wide
                ? _buildWideLayout(context)
                : _buildStackedLayout(context);
          },
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
            children: _buildInfoPanel(context),
          ),
        ),
      ],
    );
  }

  /// Single-column layout for narrow windows and phones.
  Widget _buildStackedLayout(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (content.imageBytes != null) ...[
          // Fixed-height stage so the layout does not jump while the image
          // decodes; the dark surface absorbs the letterboxing.
          SizedBox(height: 420, child: _buildImagePane(context)),
          const SizedBox(height: 12),
          ResultActionBar(content: content),
          const SizedBox(height: 4),
        ],
        ..._buildInfoPanel(context),
      ],
    );
  }

  /// The image on a dark rounded stage, like the official result viewer.
  Widget _buildImagePane(BuildContext context) {
    if (content.imageBytes == null) return const SizedBox.shrink();
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
                child: Image.memory(
                  content.imageBytes!,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
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

    return [
      if (content.info.isNotEmpty)
        _buildTextCard(context, tr('detail_prompt_blocks'), content.info),
      if (input is String && input.isNotEmpty)
        _buildTextCard(context, tr('detail_prompt_final'), input),
      if (negative is String && negative.isNotEmpty)
        _buildTextCard(context, tr('detail_negative'), negative),
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
  Widget _buildTextCard(BuildContext context, String title, String body) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
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
            SelectableText(
              body,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
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
            value: percent == null ? null : percent / 100,
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
