import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/data/services/generated_image_jpeg_encoder.dart';

class DelayedFileService extends FileService {
  final started = Completer<void>();
  final release = Completer<void>();
  bool written = false;
  @override
  Future<GeneratedImageSaveResult> saveGeneratedImage(
      Uint8List bytes, String fileName, String saveDir) async {
    started.complete();
    await release.future;
    final f = File('$saveDir/$fileName');
    await f.writeAsBytes(bytes, flush: true);
    written = true;
    return GeneratedImageSaveResult(
        destination: GeneratedImageSaveDestination.fileSystem, path: f.path);
  }
}

class FlakyEncoder implements GeneratedImageJpegEncoder {
  int calls = 0;
  final Uint8List jpeg;
  final bool failOnce;
  FlakyEncoder(this.jpeg, {this.failOnce = true});
  @override
  Future<GeneratedImageJpegEncodingResult> encode(Uint8List bytes) async {
    calls++;
    if (failOnce && calls == 1) {
      throw StateError('simulated transient JPEG worker failure');
    }
    return GeneratedImageJpegEncodingResult.encoded(
        jpegBytes: jpeg, width: 128, height: 128);
  }
}

Uint8List fixturePng() {
  final image = img.Image(width: 128, height: 128, numChannels: 3);
  final r = Random(91);
  for (final p in image) {
    p.r = r.nextInt(256);
    p.g = r.nextInt(256);
    p.b = r.nextInt(256);
  }
  return Uint8List.fromList(img.encodePng(image));
}

const metadata = GeneratedImageMetadataPolicy(
    eraseMetadata: false,
    customMetadataEnabled: false,
    customMetadataContent: '');
GeneratedImageStorageRequest request(Uint8List bytes, String output,
        {bool jpeg = false, bool retain = false, String? pngOutput}) =>
    GeneratedImageStorageRequest(
        logicalTaskId: 'PAID_TASK_FIXTURE',
        pngBytes: bytes,
        fileName: 'PAID_RESULT.png',
        storagePolicy: jpeg
            ? GeneratedImageStoragePolicy(
                jpegEnabled: true,
                retainOriginalPng: retain,
                pngOutputDirectory: pngOutput ?? output,
                jpegOutputDirectory: output)
            : GeneratedImageStoragePolicy.pngOnly(outputDirectory: output),
        metadataPolicy: metadata);
void main() {
  storageRecoveryGuards();
  test(
      'IMG-01 PNG save must remain pending and delay close until permanent bytes exist',
      () async {
    final dir = await Directory.systemTemp.createTemp('casrand-png-close-');
    final files = DelayedFileService();
    final storage = GeneratedImageStorageService(
        desktopJpegSupported: true, fileService: files);
    final submission = storage.submit(request(fixturePng(), dir.path));
    await files.started.future;
    final pendingBeforeClose = storage.hasPendingWork;
    var closed = false;
    final closeFuture = storage.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final closedBeforeWrite = closed;
    final writtenBeforeClose = files.written;
    debugPrint(
        'IMG-01 pending=$pendingBeforeClose closedBeforeWrite=$closedBeforeWrite written=$writtenBeforeClose artifact=${submission.artifact.status}');
    files.release.complete();
    await submission.completed;
    await closeFuture;
    await dir.delete(recursive: true);
    expect(pendingBeforeClose, isTrue, reason: 'Paid PNG remains unsaved.');
    expect(closedBeforeWrite, isFalse,
        reason: 'Orderly close must wait for accepted PNG publication.');
  });
  for (final retain in [false, true]) {
    test(
        'IMG-02 JPEG storage retry must recover after encoder failure retain=$retain',
        () async {
      final root = await Directory.systemTemp.createTemp('casrand-jpeg-retry-');
      final output = await Directory('${root.path}/output').create();
      final png = fixturePng();
      final jpeg =
          Uint8List.fromList(img.encodeJpg(img.decodePng(png)!, quality: 92));
      final encoder = FlakyEncoder(jpeg);
      final storage = GeneratedImageStorageService(
          desktopJpegSupported: true,
          jpegEncoder: encoder,
          sessionDirectoryProvider: () =>
              Directory('${root.path}/session').create());
      final accepted = request(png, output.path, jpeg: true, retain: retain);
      final first = storage.submit(accepted);
      await expectLater(first.completed, throwsStateError);
      Object? retryError;
      GeneratedImageArtifact? result;
      try {
        result = await storage.submit(accepted).completed;
      } catch (e) {
        retryError = e;
      }
      debugPrint(
          'IMG-02 retain=$retain firstFile=${first.artifact.currentFile?.path} retryError=$retryError encoderCalls=${encoder.calls}');
      await storage.close();
      await root.delete(recursive: true);
      expect(retryError, isNull,
          reason:
              'Same paid response should retry local storage rather than collide with its own source PNG.');
      expect(result?.isDurablySaved, isTrue);
      expect(encoder.calls, 2);
    });
  }
  test(
      'IMG-02B repairing a real blocked JPEG output directory should make retry usable',
      () async {
    final root =
        await Directory.systemTemp.createTemp('casrand-jpeg-real-failure-');
    final outputPath = '${root.path}/selected-output';
    await File(outputPath).writeAsString('temporary obstruction');
    final png = fixturePng();
    final encoder = FlakyEncoder(
        Uint8List.fromList(img.encodeJpg(img.decodePng(png)!, quality: 92)),
        failOnce: false);
    final storage = GeneratedImageStorageService(
        desktopJpegSupported: true,
        jpegEncoder: encoder,
        sessionDirectoryProvider: () =>
            Directory('${root.path}/session').create());
    final accepted = request(png, outputPath, jpeg: true);
    final first = storage.submit(accepted);
    await expectLater(first.completed, throwsA(isA<FileSystemException>()));
    await File(outputPath).delete();
    await Directory(outputPath).create();
    Object? retryError;
    try {
      await storage.submit(accepted).completed;
    } catch (e) {
      retryError = e;
    }
    debugPrint(
        'IMG-02B original=${first.artifact.failure} retry=$retryError calls=${encoder.calls}');
    await storage.close();
    await root.delete(recursive: true);
    expect(retryError, isNull,
        reason:
            'Filesystem obstruction has been removed; remaining failure is a self-created source collision.');
  });
  test('control PNG successful storage publishes actual bytes', () async {
    final dir = await Directory.systemTemp.createTemp('casrand-png-control-');
    final files = DelayedFileService();
    final storage = GeneratedImageStorageService(
        desktopJpegSupported: true, fileService: files);
    final bytes = fixturePng();
    final submission = storage.submit(request(bytes, dir.path));
    await files.started.future;
    files.release.complete();
    final artifact = await submission.completed;
    expect(artifact.isDurablySaved, isTrue);
    expect(await File(artifact.currentFile!.path).readAsBytes(), bytes);
    await storage.close();
    await dir.delete(recursive: true);
  });
}

void storageRecoveryGuards() {
  for (final sameRequest in [true, false]) {
    test(
        'JPEG retry preserves replaced files and rejects new-request ownership sameRequest=$sameRequest',
        () async {
      final root =
          await Directory.systemTemp.createTemp('casrand-storage-ownership-');
      addTearDown(() => root.delete(recursive: true));
      final output = await Directory('${root.path}/output').create();
      final png = fixturePng();
      final encoder = FlakyEncoder(
          Uint8List.fromList(img.encodeJpg(img.decodePng(png)!, quality: 92)));
      final storage = GeneratedImageStorageService(
        desktopJpegSupported: true,
        jpegEncoder: encoder,
        sessionDirectoryProvider: () =>
            Directory('${root.path}/session').create(),
      );
      final accepted = request(png, output.path, jpeg: true, retain: true);
      final first = storage.submit(accepted);
      await expectLater(first.completed, throwsStateError);
      final original = File(first.artifact.currentFile!.path);
      final preserved = sameRequest
          ? Uint8List.fromList([91, 81, 71])
          : await original.readAsBytes();
      if (sameRequest) await original.writeAsBytes(preserved, flush: true);
      final retry = storage.submit(sameRequest
          ? accepted
          : request(png, output.path, jpeg: true, retain: true));
      await expectLater(retry.completed, throwsA(isA<FileSystemException>()));
      expect(encoder.calls, 1);
      expect(await original.readAsBytes(), preserved);
      await storage.close();
    });
  }

  test(
      'JPEG identical external PNG is not adopted as a paid-request intermediate',
      () async {
    final root =
        await Directory.systemTemp.createTemp('casrand-storage-external-');
    addTearDown(() => root.delete(recursive: true));
    final png = fixturePng();
    final source = File('${root.path}/PAID_RESULT.png');
    await source.writeAsBytes(png, flush: true);
    final encoder = FlakyEncoder(Uint8List.fromList([1, 2]), failOnce: false);
    final storage = GeneratedImageStorageService(
        desktopJpegSupported: true, jpegEncoder: encoder);
    await expectLater(
        storage
            .submit(request(png, root.path, jpeg: true, retain: true))
            .completed,
        throwsA(isA<FileSystemException>()));
    expect(await source.readAsBytes(), png);
    expect(encoder.calls, 0);
    await storage.close();
  });

  test('platform PNG fallback is included in pending count and waitForIdle',
      () async {
    final root =
        await Directory.systemTemp.createTemp('casrand-storage-platform-');
    addTearDown(() => root.delete(recursive: true));
    final files = DelayedFileService();
    final storage = GeneratedImageStorageService(
        desktopJpegSupported: false, fileService: files);
    final accepted =
        storage.submit(request(fixturePng(), root.path, jpeg: true));
    await files.started.future;
    expect(storage.pendingJobCount, 1);
    var idle = false;
    final waiting = storage.waitForIdle().then((_) => idle = true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(idle, isFalse);
    files.release.complete();
    await accepted.completed;
    await waiting;
    expect(storage.pendingJobCount, 0);
    expect(files.written, isTrue);
    await storage.close();
  });
}
