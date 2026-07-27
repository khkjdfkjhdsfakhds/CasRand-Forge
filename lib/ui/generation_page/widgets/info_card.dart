import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generated_image_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/result_actions.dart';
import 'package:flutter_command/flutter_command.dart';

class InfoCard extends StatelessWidget {
  final Command<void, InfoCardContent> command;

  CommandStatus get commandStatus => GetIt.I();
  Settings get settings => GetIt.I<PayloadConfig>().settings;

  const InfoCard({super.key, required this.command});

  @override
  Widget build(BuildContext context) {
    final cardBody = ListenableBuilder(
      listenable: command.isExecuting,
      builder: (context, child) {
        if (command.isExecuting.value) {
          final current = commandStatus.currentGenerationCount.toString();
          final total = settings.generationCount != 0
              ? settings.generationCount.toString()
              : '∞';
          // Loading
          return ListTile(
            leading: const CircularProgressIndicator(),
            title: Text('Requesting $current/$total ...'),
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
        onTap: () => _showDetailedInfoDialog(context),
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
      parts.add(tr('anlas_info', namedArgs: {
        'cost': content.anlasCost.toString(),
        'remaining': content.anlasRemaining?.toString() ?? '?',
      }));
    } else if (content.anlasRemaining != null) {
      parts.add(tr('anlas_remaining_only', namedArgs: {
        'remaining': content.anlasRemaining.toString(),
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
  final InfoCardContent content;

  const InfoDetailPage({super.key, required this.content});

  @override
  State<InfoDetailPage> createState() => _InfoDetailPageState();
}

class _InfoDetailPageState extends State<InfoDetailPage> {
  final FocusNode _focusNode = FocusNode();

  InfoCardContent get content => widget.content;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space &&
        content.imageBytes != null) {
      _openFullscreenImage(context, content);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            Text(content.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (content.imageBytes != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  tr('detail_shortcut_hint'),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ),
            ),
        ],
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
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: GeneratedImageView(
        content: content,
        child: GestureDetector(
          key: const Key('detail-image-zoom-target'),
          onTap: () => _openFullscreenImage(context, content),
          child: Image.memory(
            content.imageBytes!,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
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
      chips.add(
          _paramChip(context, tr('anlas_cost'), content.anlasCost.toString()));
    }
    if (content.anlasRemaining != null) {
      chips.add(_paramChip(
          context, tr('anlas_remaining'), content.anlasRemaining.toString()));
    }
    if (chips.isEmpty) return const SizedBox.shrink();

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
          ],
        ),
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

  void _openFullscreenImage(BuildContext context, InfoCardContent content) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => FullscreenImageView(content: content),
      ),
    );
  }
}

/// Fullscreen viewer with pinch/scroll zoom and panning. Space or Escape
/// returns to the detail page.
class FullscreenImageView extends StatefulWidget {
  final InfoCardContent content;

  const FullscreenImageView({super.key, required this.content});

  @override
  State<FullscreenImageView> createState() => _FullscreenImageViewState();
}

class _FullscreenImageViewState extends State<FullscreenImageView> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(
          widget.content.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Center(
          child: InteractiveViewer(
            key: const Key('fullscreen-image-viewer'),
            minScale: 1.0,
            maxScale: 8.0,
            child: Image.memory(
              widget.content.imageBytes!,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      ),
    );
  }
}
