import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/services/file_service.dart';

class _FakeAndroidGalleryWriter implements AndroidGalleryWriter {
  _FakeAndroidGalleryWriter({
    required this.permissionGranted,
    required this.result,
  });

  final bool permissionGranted;
  final AndroidGalleryWriteResult result;
  int saveCalls = 0;

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<AndroidGalleryWriteResult> saveImage(
    Uint8List bytes, {
    required String name,
  }) async {
    saveCalls++;
    return result;
  }
}

void main() {
  test(
    'writes generated images to the selected macOS output directory',
    () async {
      final outputDirectory = await Directory.systemTemp.createTemp(
        'nai-casrand-output-',
      );
      addTearDown(() => outputDirectory.delete(recursive: true));

      final nestedOutputDirectory = Directory(
        '${outputDirectory.path}${Platform.pathSeparator}nested'
        '${Platform.pathSeparator}output',
      );

      final imageBytes = Uint8List.fromList([1, 2, 3, 4]);
      final savedPath = await FileService().savePictureToFile(
        imageBytes,
        'generated.png',
        nestedOutputDirectory.path,
      );

      final outputFile = File(
        '${nestedOutputDirectory.path}${Platform.pathSeparator}generated.png',
      );
      expect(savedPath, outputFile.absolute.path);
      expect(await outputFile.readAsBytes(), imageBytes);
    },
    skip: !Platform.isMacOS,
  );

  test('returns null when encrypted asset keys are not configured', () async {
    expect(await FileService().decryptAsset('unused-asset'), isNull);
  });

  test('Android permission denial is a failed durable save', () async {
    final gallery = _FakeAndroidGalleryWriter(
      permissionGranted: false,
      result: const AndroidGalleryWriteResult(isSuccess: true),
    );
    final service = FileService(
      targetPlatform: TargetPlatform.android,
      isWeb: false,
      androidGalleryWriter: gallery,
    );

    await expectLater(
      service.saveGeneratedImage(Uint8List(0), 'denied.png', ''),
      throwsA(predicate((error) => error.toString().contains('denied'))),
    );
    expect(gallery.saveCalls, 0);
  });

  test('Android plugin failure is not reported as saved', () async {
    final gallery = _FakeAndroidGalleryWriter(
      permissionGranted: true,
      result: const AndroidGalleryWriteResult(
        isSuccess: false,
        errorMessage: 'MediaStore write failed',
      ),
    );
    final service = FileService(
      targetPlatform: TargetPlatform.android,
      isWeb: false,
      androidGalleryWriter: gallery,
    );

    await expectLater(
      service.saveGeneratedImage(Uint8List(0), 'failed.png', ''),
      throwsA(
        predicate((error) => error.toString().contains('MediaStore')),
      ),
    );
  });

  test('Android gallery success is durable without a file-system path',
      () async {
    final gallery = _FakeAndroidGalleryWriter(
      permissionGranted: true,
      result: const AndroidGalleryWriteResult(isSuccess: true),
    );
    final service = FileService(
      targetPlatform: TargetPlatform.android,
      isWeb: false,
      androidGalleryWriter: gallery,
    );

    final result =
        await service.saveGeneratedImage(Uint8List(0), 'saved.png', '');

    expect(result.destination, GeneratedImageSaveDestination.androidGallery);
    expect(result.path, isNull);
  });

  test('legacy Android requests storage permission but modern Android does not',
      () async {
    var permissionCalls = 0;
    final legacy = PlatformAndroidGalleryWriter(
      sdkIntProvider: () async => 28,
      legacyPermissionRequester: () async {
        permissionCalls++;
        return true;
      },
    );
    final modern = PlatformAndroidGalleryWriter(
      sdkIntProvider: () async => 33,
      legacyPermissionRequester: () async {
        permissionCalls++;
        return false;
      },
    );

    expect(await legacy.requestPermission(), isTrue);
    expect(await modern.requestPermission(), isTrue);
    expect(permissionCalls, 1);
  });
}
