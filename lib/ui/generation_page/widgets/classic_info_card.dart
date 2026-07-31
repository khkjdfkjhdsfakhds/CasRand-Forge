import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generated_image_view.dart';
import 'package:nai_casrand/ui/generation_page/widgets/info_card.dart';

/// 0.55-style tidy result card: bordered rectangle showing the image and the
/// generated prompt side by side, plus the Anlas cost of the generation.
class ClassicInfoCard extends StatelessWidget {
  final Command<void, InfoCardContent> command;
  final VoidCallback? onOpenDetail;

  CommandStatus get commandStatus => GetIt.I();
  Settings get settings => GetIt.I<PayloadConfig>().settings;

  const ClassicInfoCard({
    super.key,
    required this.command,
    this.onOpenDetail,
  });

  @override
  Widget build(BuildContext context) {
    final body = ListenableBuilder(
      listenable: command.isExecuting,
      builder: (context, child) {
        if (command.isExecuting.value) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(commandStatus.requestingLabel(
                  command,
                  configuredTotal: settings.generationCount,
                )),
              ],
            ),
          );
        }
        return _buildContent(context, command.value);
      },
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4.0),
      ),
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: onOpenDetail ?? () => _showDetail(context),
        child: body,
      ),
    );
  }

  void _showDetail(BuildContext context) {
    if (command.isExecuting.value) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InfoDetailPage(content: command.value),
      ),
    );
  }

  Widget _buildContent(BuildContext context, InfoCardContent content) {
    if (content.imageBytes == null) {
      return Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    content.title,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Text(
                content.info,
                softWrap: true,
                overflow: TextOverflow.fade,
              ),
            ),
          ],
        ),
      );
    }

    final promptText = _promptText(content);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: GeneratedImageView(
            content: content,
            child: Image.memory(
              content.imageBytes!,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  content.title,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const Divider(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    primary: false,
                    child: Text(
                      promptText,
                      softWrap: true,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _buildAnlasLine(context, content),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The per-block breakdown ("--角色: ..." / "--内容: ...") rather than the
  /// flattened prompt, so the card shows what each config block contributed.
  String _promptText(InfoCardContent content) {
    if (content.info.isNotEmpty) return content.info;
    final input = content.additionalInfo['input'];
    return input is String ? input : '';
  }

  Widget _buildAnlasLine(BuildContext context, InfoCardContent content) {
    final chips = <Widget>[];
    if (content.tokenLabel != null) {
      chips.add(_chip(context, content.tokenLabel!, Icons.key_outlined));
    }
    if (content.anlasCost != null || content.anlasRemaining != null) {
      final String label;
      if (content.anlasCost != null && content.anlasCostIsEstimated) {
        final key =
            content.anlasRemaining != null && content.batchAnlasCost == null
                ? 'anlas_estimated_with_remaining'
                : 'anlas_estimated_info';
        label = tr(key, namedArgs: {
          'cost': content.anlasCost.toString(),
          'remaining': content.anlasRemaining?.toString() ?? '?',
        });
      } else if (content.anlasCost != null) {
        label = tr('anlas_info', namedArgs: {
          'cost': content.anlasCost.toString(),
          'remaining': content.anlasRemaining?.toString() ?? '?',
        });
      } else {
        label = tr('anlas_remaining_only', namedArgs: {
          'remaining': content.anlasRemaining.toString(),
        });
      }
      chips.add(_chip(context, label, Icons.toll_outlined));
    }
    if (content.batchAnlasCost != null) {
      chips.add(_chip(
        context,
        tr('anlas_batch_info', namedArgs: {
          'cost': content.batchAnlasCost.toString(),
          'remaining': content.anlasRemaining?.toString() ?? '?',
        }),
        Icons.receipt_long_outlined,
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }

  Widget _chip(BuildContext context, String label, IconData icon) {
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
