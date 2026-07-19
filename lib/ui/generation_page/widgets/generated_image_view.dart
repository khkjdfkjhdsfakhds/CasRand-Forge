import 'dart:io';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/ui/core/utils/flushbar.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

enum GeneratedImageAction {
  copyOriginal,
  showInFinder,
}

List<PopupMenuEntry<GeneratedImageAction>> buildGeneratedImageMenuItems({
  required String copyOriginalLabel,
  required String showInFinderLabel,
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

class GeneratedImageTransferService {
  const GeneratedImageTransferService();

  Future<Uint8List> readOriginalBytes(String imageFilePath) async {
    return File(imageFilePath).readAsBytes();
  }

  Future<DragItem> createDragItem(String imageFilePath) async {
    final file = File(imageFilePath);
    final item = DragItem(
      localData: imageFilePath,
      suggestedName: file.uri.pathSegments.last,
    );
    item.add(Formats.fileUri(file.uri));
    item.add(Formats.png(await readOriginalBytes(imageFilePath)));
    return item;
  }

  Future<DataWriterItem> createClipboardItem(String imageFilePath) async {
    final file = File(imageFilePath);
    final item = DataWriterItem(suggestedName: file.uri.pathSegments.last);
    item.add(Formats.png(await readOriginalBytes(imageFilePath)));
    item.add(Formats.fileUri(file.uri));
    return item;
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
    final imageFilePath = content.imageFilePath;
    if (imageFilePath == null || imageFilePath.isEmpty) return child;

    final contextMenuRegion = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) => _showContextMenu(
        context,
        details.globalPosition,
        imageFilePath,
      ),
      child: child,
    );
    if (!nativeDragEnabled) return contextMenuRegion;

    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: (_) => _createDragItem(context, imageFilePath),
      child: DraggableWidget(
        hitTestBehavior: HitTestBehavior.opaque,
        child: contextMenuRegion,
      ),
    );
  }

  Future<DragItem?> _createDragItem(
    BuildContext context,
    String imageFilePath,
  ) async {
    try {
      final file = File(imageFilePath);
      if (!await file.exists()) {
        if (context.mounted) showErrorBar(context, tr('image_file_not_found'));
        return null;
      }

      return transferService.createDragItem(imageFilePath);
    } catch (_) {
      if (context.mounted) showErrorBar(context, tr('failed'));
      return null;
    }
  }

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
    String imageFilePath,
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
        showFinder: Platform.isMacOS,
      ),
    );

    if (!context.mounted || action == null) return;
    switch (action) {
      case GeneratedImageAction.copyOriginal:
        await _copyOriginalImage(context, imageFilePath);
      case GeneratedImageAction.showInFinder:
        await _showInFinder(context, imageFilePath);
    }
  }

  Future<void> _copyOriginalImage(
    BuildContext context,
    String imageFilePath,
  ) async {
    try {
      final file = File(imageFilePath);
      if (!await file.exists()) {
        if (context.mounted) showErrorBar(context, tr('image_file_not_found'));
        return;
      }

      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        if (context.mounted) showErrorBar(context, tr('failed'));
        return;
      }

      final item = await transferService.createClipboardItem(imageFilePath);
      await clipboard.write([item]);
      if (!context.mounted) return;
      showInfoBar(context, '${tr('copy_original_image')}${tr('succeed')}');
    } catch (_) {
      if (context.mounted) showErrorBar(context, tr('failed'));
    }
  }

  Future<void> _showInFinder(
    BuildContext context,
    String imageFilePath,
  ) async {
    final file = File(imageFilePath);
    if (!await file.exists()) {
      if (context.mounted) showErrorBar(context, tr('image_file_not_found'));
      return;
    }

    final result = await Process.run('open', ['-R', file.absolute.path]);
    if (result.exitCode != 0 && context.mounted) {
      showErrorBar(context, tr('failed'));
    }
  }
}
