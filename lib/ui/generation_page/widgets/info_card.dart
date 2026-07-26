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

class InfoDetailPage extends StatelessWidget {
  final InfoCardContent content;

  const InfoDetailPage({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    List<Widget> contents = [
      buildInfoTile(tr('title'), content.title, context),
      buildInfoTile(tr('info'), content.info, context),
      if (content.tokenLabel != null)
        buildInfoTile(tr('api_token'), content.tokenLabel!, context),
      if (content.anlasCost != null)
        buildInfoTile(
          tr('anlas_cost'),
          content.anlasCost.toString(),
          context,
        ),
      if (content.anlasRemaining != null)
        buildInfoTile(
          tr('anlas_remaining'),
          content.anlasRemaining.toString(),
          context,
        ),
    ];
    for (final item in content.additionalInfo.entries) {
      contents.add(buildInfoTile(item.key, item.value.toString(), context));
    }

    final body = Scaffold(
      appBar: AppBar(title: Text(content.title)),
      body: SingleChildScrollView(
        child: Column(
          children: [
            if (content.imageBytes != null)
              GeneratedImageView(
                content: content,
                child: GestureDetector(
                  key: const Key('detail-image-zoom-target'),
                  onTap: () => _openFullscreenImage(context, content),
                  child: Image.memory(content.imageBytes!, fit: BoxFit.contain),
                ),
              ),
            ...contents,
          ],
        ),
      ),
    );

    // Tapping outside the image closes the page; the image itself zooms.
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: body,
    );
  }

  void _openFullscreenImage(BuildContext context, InfoCardContent content) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => FullscreenImageView(content: content),
      ),
    );
  }

  Widget buildInfoTile(String title, String content, BuildContext context) {
    return Column(children: [
      ListTile(
        titleAlignment: ListTileTitleAlignment.top,
        title: Text(title),
        subtitle: SelectableText(content),
        trailing: IconButton(
            onPressed: () {
              Navigator.of(context).pop();
              _copyContent(content, context);
            },
            tooltip: tr('copy_to_clipboard'),
            icon: const Icon(Icons.copy)),
      ),
      const Divider(),
    ]);
  }

  void _copyContent(String content, BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (!context.mounted) return;
    showInfoBar(context, '${tr('info_export_to_clipboard')}${tr('succeed')}');
  }

  getSelectableTextPage(String title, String text) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('selectable') + tr('colon') + title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SelectableText(text),
      ),
    );
  }
}

/// Fullscreen viewer with pinch/scroll zoom and panning.
class FullscreenImageView extends StatelessWidget {
  final InfoCardContent content;

  const FullscreenImageView({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(
          content.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Center(
        child: InteractiveViewer(
          key: const Key('fullscreen-image-viewer'),
          minScale: 1.0,
          maxScale: 8.0,
          child: Image.memory(
            content.imageBytes!,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
      ),
    );
  }
}
