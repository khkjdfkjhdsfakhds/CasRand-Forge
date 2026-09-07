import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:nai_casrand/ui/core/utils/platform_support.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

enum GeneratedImageAction {
  copyOriginal,
  copyRetainedPng,
  showInFinder,
}

List<PopupMenuEntry<GeneratedImageAction>> buildGeneratedImageMenuItems({
  required String copyOriginalLabel,
  required String showInFinderLabel,
  String? copyRetainedPngLabel,
  bool showFinder = true,
}) {
  return [
    PopupMenuItem(
      value: GeneratedImageAction.copyOriginal,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.copy),
        title: Text(copyOriginalLabel),
      ),
    ),
    if (copyRetainedPngLabel != null)
      PopupMenuItem(
        value: GeneratedImageAction.copyRetainedPng,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.image_outlined),
          title: Text(copyRetainedPngLabel),
        ),
      ),
    if (showFinder)
      PopupMenuItem(
        value: GeneratedImageAction.showInFinder,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_open),
          title: Text(showInFinderLabel),
        ),
      ),
  ];
}

String? generatedImageStorageStatusKey(GeneratedImageStorageStatus status) {
  return switch (status) {
    GeneratedImageStorageStatus.queued ||
    GeneratedImageStorageStatus.savingSessionPng ||
    GeneratedImageStorageStatus.encoding ||
    GeneratedImageStorageStatus.publishing =>
      'jpeg_storage_in_progress',
    GeneratedImageStorageStatus.jpegSaved => null,
    GeneratedImageStorageStatus.pngFallbackSaved => 'jpeg_storage_png_fallback',
    GeneratedImageStorageStatus.skippedNotSmaller =>
      'jpeg_storage_skipped_not_smaller',
    GeneratedImageStorageStatus.failed => 'jpeg_storage_failed',
    GeneratedImageStorageStatus.abandoned => 'jpeg_storage_abandoned',
    GeneratedImageStorageStatus.saving ||
    GeneratedImageStorageStatus.saved =>
      null,
  };
}

String? generatedImageMetadataStatusKey({
  required ImageMetadataEmbeddingMode? mode,
  required Object? failure,
}) {
  if (failure != null) return 'generated_image_metadata_failed';
  if (mode == ImageMetadataEmbeddingMode.pngInternationalText) {
    return 'generated_image_metadata_fallback';
  }
  return null;
}

class GeneratedImageTransferService {
  final Future<ProcessResult> Function(String, List<String>) processRunner;

  const GeneratedImageTransferService({
    this.processRunner = Process.run,
  });

  Future<Uint8List> readOriginalBytes(GeneratedImageFile imageFile) async {
    return File(imageFile.path).readAsBytes();
  }

  Future<DragItem> createDragItem(GeneratedImageFile imageFile) async {
    final file = File(imageFile.path);
    final item = DragItem(
      localData: imageFile.path,
      suggestedName: file.uri.pathSegments.last,
    );
    item.add(Formats.fileUri(file.uri));
    final bytes = await readOriginalBytes(imageFile);
    item.add(_imageFormat(imageFile).call(bytes));
    return item;
  }

  Future<DataWriterItem> createClipboardItem(
    GeneratedImageFile imageFile,
  ) async {
    final file = File(imageFile.path);
    final item = DataWriterItem(suggestedName: file.uri.pathSegments.last);
    final bytes = await readOriginalBytes(imageFile);
    item.add(_imageFormat(imageFile).call(bytes));
    item.add(Formats.fileUri(file.uri));
    return item;
  }

  Future<bool> revealInFileManager(GeneratedImageFile imageFile) async {
    final result = await processRunner('open', ['-R', imageFile.path]);
    return result.exitCode == 0;
  }

  SimpleFileFormat _imageFormat(GeneratedImageFile imageFile) {
    return imageFile.mediaType == 'image/jpeg' ? Formats.jpeg : Formats.png;
  }
}

class GeneratedImageView extends StatelessWidget {
  final InfoCardContent content;
  final Widget child;
  final bool nativeDragEnabled;
  final GeneratedImageTransferService transferService;

  const GeneratedImageView({
    super.key,
    required this.content,
    required this.child,
    this.nativeDragEnabled = true,
    this.transferService = const GeneratedImageTransferService(),
  });

  @override
  Widget build(BuildContext context) {
    final artifact = content.imageArtifact;
    if (artifact == null) return child;
    return ListenableBuilder(
      listenable: artifact,
      child: child,
      builder: (context, child) {
        final actions = _buildFileActions(context, artifact, child!);
        final statusKey = generatedImageStorageStatusKey(artifact.status);
        final metadataStatusKey = generatedImageMetadataStatusKey(
          mode: artifact.metadataEmbeddingMode,
          failure: artifact.metadataFailure,
        );
        if (statusKey == null && metadataStatusKey == null) return actions;
        final statusMessages = [
          if (statusKey != null) tr(statusKey),
          if (metadataStatusKey != null)
            tr(
              metadataStatusKey,
              namedArgs: {
                'error': artifact.metadataFailure?.toString() ?? '',
              },
            ),
        ];
        return Stack(
          fit: StackFit.expand,
          children: [
            actions,
            Positioned(
              left: 8,
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final message in statusMessages)
                              Text(
                                message,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                          ],
                        ),
                      ),
                      if (artifact.status ==
                              GeneratedImageStorageStatus.failed &&
                          content.retryImageStorage != null) ...[
                        const SizedBox(width: 8),
                        TextButton.icon(
                          key: const Key('retry-generated-image-storage'),
                          onPressed: () async {
                            await content.retryImageStorage!();
                          },
                          icon: const Icon(Icons.refresh, size: 16),
                          label: Text(tr('retry')),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFileActions(
    BuildContext context,
    GeneratedImageArtifact artifact,
    Widget child,
  ) {
    final imageFile = artifact.currentFile;
    if (imageFile == null || imageFile.path.isEmpty) return child;

    final contextMenuRegion = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) => _showContextMenu(
        context,
        details.globalPosition,
        imageFile,
        artifact.originalPngFile,
      ),
      child: child,
    );
    if (!nativeDragEnabled || !supportsSuperNativeExtensions) {
      return contextMenuRegion;
    }

    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: (_) => _createDragItem(context, imageFile),
      child: DraggableWidget(
        hitTestBehavior: HitTestBehavior.opaque,
        child: contextMenuRegion,
      ),
    );
  }

  Future<DragItem?> _createDragItem(
    BuildContext context,
    GeneratedImageFile imageFile,
  ) async {
    try {
      final file = File(imageFile.path);
      if (!await file.exists()) {
        if (context.mounted) showErrorBar(context, tr('image_file_not_found'));
        return null;
      }

      return transferService.createDragItem(imageFile);
    } catch (_) {
      if (context.mounted) showErrorBar(context, tr('failed'));
      return null;
    }
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
    GeneratedImageFile imageFile,
    GeneratedImageFile? originalPngFile,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = overlay.globalToLocal(globalPosition);
    final action = await showMenu<GeneratedImageAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: buildGeneratedImageMenuItems(
        copyOriginalLabel: context.tr('copy_original_image'),
        showInFinderLabel: context.tr('show_in_finder'),
        copyRetainedPngLabel: originalPngFile?.isPermanent == true &&
                originalPngFile?.path != imageFile.path
            ? context.tr('copy_original_png')
            : null,
        showFinder: Platform.isMacOS,
      ),
    );

    if (!context.mounted || action == null) return;
    switch (action) {
      case GeneratedImageAction.copyOriginal:
        await _copyOriginalImage(context, imageFile);
      case GeneratedImageAction.copyRetainedPng:
        if (originalPngFile != null) {
          await _copyOriginalImage(context, originalPngFile);
        }
      case GeneratedImageAction.showInFinder:
        await _showInFinder(context, imageFile);
    }
  }

  Future<void> _copyOriginalImage(
    BuildContext context,
    GeneratedImageFile imageFile,
  ) async {
    try {
      final file = File(imageFile.path);
      if (!await file.exists()) {
        if (context.mounted) showErrorBar(context, tr('image_file_not_found'));
        return;
      }

      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        if (context.mounted) showErrorBar(context, tr('failed'));
        return;
      }

      final item = await transferService.createClipboardItem(imageFile);
      await clipboard.write([item]);
      if (!context.mounted) return;
      showInfoBar(context, '${tr('copy_original_image')}${tr('succeed')}');
    } catch (_) {
      if (context.mounted) showErrorBar(context, tr('failed'));
    }
  }

  Future<void> _showInFinder(
    BuildContext context,
    GeneratedImageFile imageFile,
  ) async {
    final file = File(imageFile.path);
    if (!await file.exists()) {
      if (context.mounted) showErrorBar(context, tr('image_file_not_found'));
      return;
    }

    final revealed = await transferService.revealInFileManager(imageFile);
    if (!revealed && context.mounted) {
      showErrorBar(context, tr('failed'));
    }
  }
}
