import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generated_image_view.dart';

void main() {
  test('generated image menu contains original-file actions', () {
    final items = buildGeneratedImageMenuItems(
      copyOriginalLabel: 'Copy Original Image',
      showInFinderLabel: 'Show in Finder',
      showFinder: true,
    );

    expect(items, hasLength(2));
    final menuItems = items.cast<PopupMenuItem<GeneratedImageAction>>();
    expect(menuItems.map((item) => item.value), [
      GeneratedImageAction.copyOriginal,
      GeneratedImageAction.showInFinder,
    ]);
    final titles = menuItems.map((item) {
      final tile = item.child as ListTile;
      return (tile.title as Text).data;
    });
    expect(titles, ['Copy Original Image', 'Show in Finder']);
  });

  test('transfer data reads the original file without re-encoding', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'nai-casrand-generated-image-transfer-',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final imageFile = File('${tempDirectory.path}/generated.png');
    final originalBytes = Uint8List.fromList([0, 255, 17, 34, 51]);
    await imageFile.writeAsBytes(originalBytes);
    const service = GeneratedImageTransferService();

    expect(await service.readOriginalBytes(imageFile.path), originalBytes);
    final dragItem = await service.createDragItem(imageFile.path);
    final clipboardItem = await service.createClipboardItem(imageFile.path);

    expect(dragItem.suggestedName, 'generated.png');
    expect(dragItem.data, hasLength(2));
    expect(clipboardItem.suggestedName, 'generated.png');
    expect(clipboardItem.data, hasLength(2));
  });
}
