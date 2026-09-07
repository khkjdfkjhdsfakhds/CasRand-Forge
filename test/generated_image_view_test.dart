import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/data/services/image_service.dart';
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

  test('retained PNG adds a distinct original-file action', () {
    final items = buildGeneratedImageMenuItems(
      copyOriginalLabel: 'Copy Current Image File',
      copyRetainedPngLabel: 'Copy Retained Original PNG',
      showInFinderLabel: 'Show in Finder',
      showFinder: true,
    ).cast<PopupMenuItem<GeneratedImageAction>>();

    expect(items.map((item) => item.value), [
      GeneratedImageAction.copyOriginal,
      GeneratedImageAction.copyRetainedPng,
      GeneratedImageAction.showInFinder,
    ]);
  });

  test('storage terminal states have explicit user-facing labels', () {
    expect(
      generatedImageStorageStatusKey(
        GeneratedImageStorageStatus.skippedNotSmaller,
      ),
      'jpeg_storage_skipped_not_smaller',
    );
    expect(
      generatedImageStorageStatusKey(GeneratedImageStorageStatus.failed),
      'jpeg_storage_failed',
    );
    expect(
      generatedImageStorageStatusKey(
        GeneratedImageStorageStatus.pngFallbackSaved,
      ),
      'jpeg_storage_png_fallback',
    );
    expect(
      generatedImageStorageStatusKey(GeneratedImageStorageStatus.saved),
      isNull,
    );
    expect(
      generatedImageStorageStatusKey(GeneratedImageStorageStatus.jpegSaved),
      isNull,
    );
  });

  test('metadata fallback and failure have explicit user-facing labels', () {
    expect(
      generatedImageMetadataStatusKey(
        mode: ImageMetadataEmbeddingMode.pngInternationalText,
        failure: null,
      ),
      'generated_image_metadata_fallback',
    );
    expect(
      generatedImageMetadataStatusKey(
        mode: ImageMetadataEmbeddingMode.stealth,
        failure: StateError('metadata failed'),
      ),
      'generated_image_metadata_failed',
    );
  });

  test('transfer data reads the original file without re-encoding', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'nai-casrand-generated-image-transfer-',
    );
    addTearDown(() => tempDirectory.delete(recursive: true));
    final imageFile = File('${tempDirectory.path}/generated.png');
    final originalBytes = Uint8List.fromList([0, 255, 17, 34, 51]);
    await imageFile.writeAsBytes(originalBytes);
    final artifactFile = GeneratedImageFile(
      path: imageFile.path,
      mediaType: 'image/png',
      isPermanent: true,
    );
    const service = GeneratedImageTransferService();

    expect(await service.readOriginalBytes(artifactFile), originalBytes);
    final dragItem = await service.createDragItem(artifactFile);
    final clipboardItem = await service.createClipboardItem(artifactFile);

    expect(dragItem.suggestedName, 'generated.png');
    expect(dragItem.data, hasLength(2));
    expect(clipboardItem.suggestedName, 'generated.png');
    expect(clipboardItem.data, hasLength(2));
  });

  test('Finder reveal selects the current artifact path', () async {
    final calls = <(String, List<String>)>[];
    final service = GeneratedImageTransferService(
      processRunner: (executable, arguments) async {
        calls.add((executable, arguments));
        return ProcessResult(1, 0, '', '');
      },
    );
    const artifactFile = GeneratedImageFile(
      path: '/output/current.jpg',
      mediaType: 'image/jpeg',
      isPermanent: true,
    );

    expect(await service.revealInFileManager(artifactFile), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.$1, 'open');
    expect(calls.single.$2, ['-R', '/output/current.jpg']);
  });

  testWidgets('failed storage keeps the preview and exposes retry',
      (tester) async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final failure = StateError('disk full');
    final submission = GeneratedImageStorageSubmission.start(
      previewBytes: bytes,
      publish: () => Future<GeneratedImageFile?>.error(failure),
    );
    await expectLater(submission.completed, throwsA(same(failure)));
    var retries = 0;
    final content = InfoCardContent(
      title: 'paid result',
      info: '',
      additionalInfo: const {},
      imageArtifact: submission.artifact,
      retryImageStorage: () async => retries++,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 320,
          child: GeneratedImageView(
            content: content,
            nativeDragEnabled: false,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    ));

    expect(content.imageBytes, same(bytes));
    expect(find.byKey(const Key('retry-generated-image-storage')), findsOne);
    await tester.tap(find.byKey(const Key('retry-generated-image-storage')));
    await tester.pump();
    expect(retries, 1);
  });
}
