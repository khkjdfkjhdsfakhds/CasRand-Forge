import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generated_image_view.dart';

/// Original/result workspace used by image transforms. It stays side by side
/// on wide screens and stacks vertically when the available width is narrow.
class ImageTransformWorkspace extends StatelessWidget {
  final Uint8List? sourceBytes;
  final InfoCardContent? result;
  final bool isExecuting;
  final Widget sourcePlaceholder;
  final Widget sourceActions;
  final VoidCallback onSourceTap;

  const ImageTransformWorkspace({
    super.key,
    required this.sourceBytes,
    required this.result,
    required this.isExecuting,
    required this.sourcePlaceholder,
    required this.sourceActions,
    required this.onSourceTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final original = _ImageStage(
          key: const Key('transform-original-stage'),
          title: tr('transform_original'),
          image: sourceBytes == null
              ? null
              : Image.memory(
                  sourceBytes!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
          placeholder: sourcePlaceholder,
          onTap: onSourceTap,
          footer: sourceActions,
        );
        final output = _ImageStage(
          key: const Key('transform-result-stage'),
          title: tr('transform_result'),
          image: _resultImage(),
          placeholder: _resultPlaceholder(context),
        );
        if (constraints.maxWidth >= 760) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: original),
              const SizedBox(width: 12),
              Expanded(child: output),
            ],
          );
        }
        return Column(
          children: [
            original,
            const SizedBox(height: 12),
            output,
          ],
        );
      },
    );
  }

  Widget? _resultImage() {
    final content = result;
    final bytes = content?.imageBytes;
    if (content == null || bytes == null) return null;
    return GeneratedImageView(
      content: content,
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  Widget _resultPlaceholder(BuildContext context) {
    if (isExecuting) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(tr('transform_processing')),
        ],
      );
    }
    final content = result;
    if (content != null && content.title.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 52,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(content.title, textAlign: TextAlign.center),
            if (content.info.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                content.info,
                textAlign: TextAlign.center,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.image_outlined,
          size: 72,
          color: Theme.of(context).disabledColor,
        ),
        const SizedBox(height: 8),
        Text(
          tr('transform_result_hint'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).disabledColor),
        ),
      ],
    );
  }
}

class _ImageStage extends StatelessWidget {
  final String title;
  final Widget? image;
  final Widget placeholder;
  final VoidCallback? onTap;
  final Widget? footer;

  const _ImageStage({
    super.key,
    required this.title,
    required this.image,
    required this.placeholder,
    this.onTap,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final stage = Container(
      width: double.infinity,
      height: 360,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: image ?? placeholder,
    );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (onTap == null) stage else InkWell(onTap: onTap, child: stage),
            if (footer != null) ...[
              const SizedBox(height: 8),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}
