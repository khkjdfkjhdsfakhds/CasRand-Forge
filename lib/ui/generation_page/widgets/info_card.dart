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
      appBar: AppBar(title: Text(content.title)),
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide =
                constraints.maxWidth >= detailWideLayoutBreakpoint &&
                    content.imageBytes != null;
            return wide ? _buildWideLayout(context) : _buildStackedLayout(context);
          },
        ),
      ),
    );
  }

  /// Image on the left, prompt and parameters on the right — the layout the
  /// result cards use, so a tall image no longer pushes the prompt off-screen.
  Widget _buildWideLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            children: [
              ResultActionBar(content: content),
              Expanded(child: _buildImage(context, fit: BoxFit.contain)),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 4,
          child: SingleChildScrollView(
            child: Column(children: _buildInfoTiles(context)),
          ),
        ),
      ],
    );
  }

  /// The original single-column layout, kept for narrow windows and phones.
  Widget _buildStackedLayout(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          if (content.imageBytes != null) ...[
            ResultActionBar(content: content),
            _buildImage(context, fit: BoxFit.contain),
          ],
          ..._buildInfoTiles(context),
        ],
      ),
    );
  }

  Widget _buildImage(BuildContext context, {required BoxFit fit}) {
    if (content.imageBytes == null) return const SizedBox.shrink();
    return GeneratedImageView(
      content: content,
      child: GestureDetector(
        key: const Key('detail-image-zoom-target'),
        onTap: () => _openFullscreenImage(context, content),
        child: Image.memory(content.imageBytes!, fit: fit),
      ),
    );
  }

  List<Widget> _buildInfoTiles(BuildContext context) {
    final tiles = <Widget>[
      buildInfoTile(tr('title'), content.title, context),
      buildInfoTile(tr('info'), content.info, context),
      if (content.tokenLabel != null)
        buildInfoTile(tr('api_token'), content.tokenLabel!, context),
      if (content.anlasCost != null)
        buildInfoTile(tr('anlas_cost'), content.anlasCost.toString(), context),
      if (content.anlasRemaining != null)
        buildInfoTile(
          tr('anlas_remaining'),
          content.anlasRemaining.toString(),
          context,
        ),
    ];
    for (final item in content.additionalInfo.entries) {
      tiles.add(buildInfoTile(item.key, item.value.toString(), context));
    }
    return tiles;
  }

  Widget buildInfoTile(String title, String body, BuildContext context) {
    return Column(children: [
      ListTile(
        titleAlignment: ListTileTitleAlignment.top,
        title: Text(title),
        subtitle: SelectableText(body),
        trailing: IconButton(
            onPressed: () => _copyContent(body, context),
            tooltip: tr('copy_to_clipboard'),
            icon: const Icon(Icons.copy)),
      ),
      const Divider(),
    ]);
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
