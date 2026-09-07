import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/services/file_service.dart';
import 'package:nai_casrand/data/services/generated_image_jpeg_encoder.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';

class _LocalFileService extends FileService {
  @override
  Future<String?> savePictureToFile(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async {
    final directory = Directory(saveDir);
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes);
    return file.absolute.path;
  }
}

class _NoLocalFileService extends FileService {
  @override
  Future<String?> savePictureToFile(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async {
    return null;
  }
}

class _ControlledJpegEncoder implements GeneratedImageJpegEncoder {
  final List<Completer<GeneratedImageJpegEncodingResult>> calls = [];

  @override
  Future<GeneratedImageJpegEncodingResult> encode(Uint8List pngBytes) {
    final call = Completer<GeneratedImageJpegEncodingResult>();
    calls.add(call);
    return call.future;
  }
}

String _pathIn(Directory directory, String name) =>
    '${directory.path}${Platform.pathSeparator}$name';

Uint8List _opaquePng({int width = 64, int height = 64}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(x, y, x * 3, y * 3, (x + y) * 2, 255);
    }
  }
  return img.encodePng(image);
}

Uint8List _noisyOpaquePng({int width = 128, int height = 128}) {
  final random = Random(42);
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
  }
  return img.encodePng(image);
}

GeneratedImageJpegEncodingResult _jpegResult(
  Uint8List jpegBytes, {
  int width = 64,
  int height = 64,
}) {
  return GeneratedImageJpegEncodingResult.encoded(
    jpegBytes: jpegBytes,
    width: width,
    height: height,
    metadataJson: null,
  );
}

GeneratedImageStorageRequest _jpegRequest(
  String id,
  String outputDirectory, {
  bool retainOriginalPng = false,
}) {
  return GeneratedImageStorageRequest(
    logicalTaskId: id,
    pngBytes: _opaquePng(),
    fileName: '$id.png',
    storagePolicy: GeneratedImageStoragePolicy(
      jpegEnabled: true,
      retainOriginalPng: retainOriginalPng,
      pngOutputDirectory: retainOriginalPng ? outputDirectory : '',
      jpegOutputDirectory: outputDirectory,
    ),
    metadataPolicy: const GeneratedImageMetadataPolicy(
      eraseMetadata: false,
      customMetadataEnabled: false,
      customMetadataContent: '',
    ),
  );
}

void main() {
  test('PNG submission exposes preview bytes before publishing its artifact',
      () async {
    final outputDirectory = await Directory.systemTemp.createTemp(
      'casrand-generated-image-storage-',
    );
    addTearDown(() => outputDirectory.delete(recursive: true));
    final pngBytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3, 4]);
    final storage = PngGeneratedImageStorage(fileService: _LocalFileService());

    final submission = storage.submit(GeneratedImageStorageRequest(
      logicalTaskId: 'test:generated',
      pngBytes: pngBytes,
      fileName: 'generated.png',
      storagePolicy: GeneratedImageStoragePolicy.pngOnly(
        outputDirectory: outputDirectory.path,
      ),
      metadataPolicy: const GeneratedImageMetadataPolicy(
        eraseMetadata: false,
        customMetadataEnabled: false,
        customMetadataContent: '',
      ),
    ));

    expect(identical(submission.artifact.previewBytes, pngBytes), isTrue);
    expect(submission.artifact.status, GeneratedImageStorageStatus.saving);
    expect(submission.artifact.currentFile, isNull);
    expect(submission.artifact.permanentFiles, isEmpty);

    final completedArtifact = await submission.completed;
    final outputFile = File(
      '${outputDirectory.path}${Platform.pathSeparator}generated.png',
    );
    expect(identical(completedArtifact, submission.artifact), isTrue);
    expect(completedArtifact.status, GeneratedImageStorageStatus.saved);
    expect(completedArtifact.currentFile?.path, outputFile.absolute.path);
    expect(completedArtifact.currentFile?.mediaType, 'image/png');
    expect(completedArtifact.permanentFiles, [completedArtifact.currentFile]);
    expect(await outputFile.readAsBytes(), pngBytes);
  });

  test('result content follows its artifact without copying preview bytes',
      () async {
    final outputDirectory = await Directory.systemTemp.createTemp(
      'casrand-generated-image-content-',
    );
    addTearDown(() => outputDirectory.delete(recursive: true));
    final pngBytes = Uint8List.fromList([137, 80, 78, 71, 9, 8, 7, 6]);
    final submission = PngGeneratedImageStorage().submit(
      GeneratedImageStorageRequest(
        logicalTaskId: 'test:result',
        pngBytes: pngBytes,
        fileName: 'result.png',
        storagePolicy: GeneratedImageStoragePolicy.pngOnly(
          outputDirectory: outputDirectory.path,
        ),
        metadataPolicy: const GeneratedImageMetadataPolicy(
          eraseMetadata: false,
          customMetadataEnabled: false,
          customMetadataContent: '',
        ),
      ),
    );
    final content = InfoCardContent(
      title: 'result.png',
      info: '',
      additionalInfo: const {},
      imageArtifact: submission.artifact,
    );

    expect(identical(content.imageBytes, pngBytes), isTrue);
    expect(content.currentImageFile, isNull);

    await submission.completed;

    expect(content.currentImageFile, same(submission.artifact.currentFile));
  });

  test('a platform save without a local path is still a successful outcome',
      () async {
    final submission = PngGeneratedImageStorage(
      fileService: _NoLocalFileService(),
    ).submit(GeneratedImageStorageRequest(
      logicalTaskId: 'android:gallery:1',
      pngBytes: Uint8List(0),
      fileName: 'gallery.png',
      storagePolicy: const GeneratedImageStoragePolicy.pngOnly(
        outputDirectory: '',
      ),
      metadataPolicy: const GeneratedImageMetadataPolicy(
        eraseMetadata: false,
        customMetadataEnabled: false,
        customMetadataContent: '',
      ),
    ));

    final artifact = await submission.completed;

    expect(artifact.status, GeneratedImageStorageStatus.saved);
    expect(artifact.currentFile, isNull);
    expect(artifact.permanentFiles, isEmpty);
  });

  test('publication failure is observable and rejects durable completion',
      () async {
    final failure = StateError('disk full');
    final publication = Completer<GeneratedImageFile?>();
    final submission = GeneratedImageStorageSubmission.start(
      previewBytes: Uint8List.fromList([1, 2, 3]),
      publish: () => publication.future,
    );

    expect(submission.artifact.status, GeneratedImageStorageStatus.saving);
    publication.completeError(failure);

    await expectLater(submission.completed, throwsA(same(failure)));
    expect(submission.artifact.status, GeneratedImageStorageStatus.failed);
    expect(submission.artifact.failure, same(failure));
    expect(submission.artifact.currentFile, isNull);
    expect(submission.artifact.permanentFiles, isEmpty);
  });

  test(
      'JPEG mode keeps a session PNG usable while encoding then atomically publishes JPEG',
      () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-jpeg-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async => session,
      maxConcurrentJpegJobs: 1,
      maxPendingJpegJobs: 2,
    );
    final pngBytes = _opaquePng();

    final submission = storage.submit(GeneratedImageStorageRequest(
      logicalTaskId: 'jpeg:success',
      pngBytes: pngBytes,
      fileName: 'result.png',
      storagePolicy: GeneratedImageStoragePolicy(
        jpegEnabled: true,
        retainOriginalPng: false,
        pngOutputDirectory: '',
        jpegOutputDirectory: output.path,
      ),
      metadataPolicy: const GeneratedImageMetadataPolicy(
        eraseMetadata: false,
        customMetadataEnabled: false,
        customMetadataContent: '',
      ),
    ));

    expect(identical(submission.artifact.previewBytes, pngBytes), isTrue);
    expect(submission.artifact.currentFile, isNull);
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final sessionFile = submission.artifact.currentFile;
    expect(sessionFile?.mediaType, 'image/png');
    expect(sessionFile?.isPermanent, isFalse);
    expect(await File(sessionFile!.path).readAsBytes(), pngBytes);
    expect(submission.artifact.status, GeneratedImageStorageStatus.encoding);

    final jpegBytes = Uint8List.fromList(List<int>.filled(128, 7));
    expect(jpegBytes.length, lessThan(pngBytes.length));
    encoder.calls.single.complete(_jpegResult(jpegBytes));
    final artifact = await submission.completed;

    final jpegFile = File('${output.path}${Platform.pathSeparator}result.jpg');
    expect(artifact.status, GeneratedImageStorageStatus.jpegSaved);
    expect(artifact.currentFile?.path, jpegFile.absolute.path);
    expect(artifact.currentFile?.mediaType, 'image/jpeg');
    expect(artifact.currentFile?.isPermanent, isTrue);
    expect(artifact.permanentFiles, [artifact.currentFile]);
    expect(await jpegFile.readAsBytes(), jpegBytes);
    expect(await File(sessionFile.path).exists(), isTrue);
    expect(
      output.listSync().whereType<File>().map((file) => file.path),
      [jpegFile.path],
    );
  });

  test('JPEG candidate that is not smaller stays on session PNG and skips',
      () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-jpeg-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async => session,
    );
    final pngBytes = _opaquePng(width: 8, height: 8);
    final submission = storage.submit(GeneratedImageStorageRequest(
      logicalTaskId: 'jpeg:larger',
      pngBytes: pngBytes,
      fileName: 'larger.png',
      storagePolicy: GeneratedImageStoragePolicy(
        jpegEnabled: true,
        retainOriginalPng: false,
        pngOutputDirectory: '',
        jpegOutputDirectory: output.path,
      ),
      metadataPolicy: const GeneratedImageMetadataPolicy(
        eraseMetadata: false,
        customMetadataEnabled: false,
        customMetadataContent: '',
      ),
    ));
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    encoder.calls.single.complete(
      _jpegResult(Uint8List(pngBytes.length), width: 8, height: 8),
    );

    final artifact = await submission.completed;

    expect(artifact.status, GeneratedImageStorageStatus.skippedNotSmaller);
    expect(artifact.currentFile?.mediaType, 'image/png');
    expect(artifact.currentFile?.isPermanent, isFalse);
    expect(artifact.permanentFiles, isEmpty);
    expect(output.listSync(), isEmpty);
  });

  test('atomic JPEG publication never overwrites an existing final file',
      () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-jpeg-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final existing = File('${output.path}${Platform.pathSeparator}same.jpg');
    await existing.writeAsBytes([1, 2, 3]);
    final encoder = _ControlledJpegEncoder();
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async => session,
    );
    final pngBytes = _opaquePng();
    final submission = storage.submit(GeneratedImageStorageRequest(
      logicalTaskId: 'jpeg:collision',
      pngBytes: pngBytes,
      fileName: 'same.png',
      storagePolicy: GeneratedImageStoragePolicy(
        jpegEnabled: true,
        retainOriginalPng: false,
        pngOutputDirectory: '',
        jpegOutputDirectory: output.path,
      ),
      metadataPolicy: const GeneratedImageMetadataPolicy(
        eraseMetadata: false,
        customMetadataEnabled: false,
        customMetadataContent: '',
      ),
    ));
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    encoder.calls.single.complete(_jpegResult(Uint8List(1)));

    await expectLater(
        submission.completed, throwsA(isA<FileSystemException>()));
    expect(await existing.readAsBytes(), [1, 2, 3]);
    expect(
      output.listSync().whereType<File>().map((file) => file.path),
      [existing.path],
    );
    expect(submission.artifact.status, GeneratedImageStorageStatus.failed);
    expect(submission.artifact.currentFile?.mediaType, 'image/png');
  });

  test('disabled JPEG policy uses legacy PNG path without encoder or session',
      () async {
    final output = await Directory.systemTemp.createTemp('casrand-png-');
    addTearDown(() => output.delete(recursive: true));
    final encoder = _ControlledJpegEncoder();
    var sessionRequested = false;
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async {
        sessionRequested = true;
        return Directory.systemTemp;
      },
      fileService: _LocalFileService(),
    );

    final artifact = await storage
        .submit(GeneratedImageStorageRequest(
          logicalTaskId: 'png:legacy',
          pngBytes: Uint8List.fromList([1, 2, 3]),
          fileName: 'legacy.png',
          storagePolicy: GeneratedImageStoragePolicy.pngOnly(
            outputDirectory: output.path,
          ),
          metadataPolicy: const GeneratedImageMetadataPolicy(
            eraseMetadata: false,
            customMetadataEnabled: false,
            customMetadataContent: '',
          ),
        ))
        .completed;

    expect(artifact.status, GeneratedImageStorageStatus.saved);
    expect(encoder.calls, isEmpty);
    expect(sessionRequested, isFalse);
    expect(await File(_pathIn(output, 'legacy.png')).readAsBytes(), [1, 2, 3]);
  });

  test('public storage seam produces a decodable smaller JPEG end to end',
      () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-jpeg-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final source = _noisyOpaquePng();
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      sessionDirectoryProvider: () async => session,
    );

    final artifact = await storage
        .submit(GeneratedImageStorageRequest(
          logicalTaskId: 'jpeg:real',
          pngBytes: source,
          fileName: 'real.png',
          storagePolicy: GeneratedImageStoragePolicy(
            jpegEnabled: true,
            retainOriginalPng: false,
            pngOutputDirectory: '',
            jpegOutputDirectory: output.path,
          ),
          metadataPolicy: const GeneratedImageMetadataPolicy(
            eraseMetadata: false,
            customMetadataEnabled: false,
            customMetadataContent: '',
          ),
        ))
        .completed;

    expect(artifact.status, GeneratedImageStorageStatus.jpegSaved);
    final jpegBytes = await File(artifact.currentFile!.path).readAsBytes();
    final reopened = img.decodeJpg(jpegBytes);
    expect(jpegBytes.length, lessThan(source.length));
    expect(reopened?.width, 128);
    expect(reopened?.height, 128);
  });

  test('one queued conversion failure does not stop the next image', () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-jpeg-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async => session,
      maxConcurrentJpegJobs: 1,
      maxPendingJpegJobs: 1,
    );
    GeneratedImageStorageSubmission submit(String id) {
      return storage.submit(GeneratedImageStorageRequest(
        logicalTaskId: id,
        pngBytes: _opaquePng(),
        fileName: '$id.png',
        storagePolicy: GeneratedImageStoragePolicy(
          jpegEnabled: true,
          retainOriginalPng: false,
          pngOutputDirectory: '',
          jpegOutputDirectory: output.path,
        ),
        metadataPolicy: const GeneratedImageMetadataPolicy(
          eraseMetadata: false,
          customMetadataEnabled: false,
          customMetadataContent: '',
        ),
      ));
    }

    final failed = submit('failed');
    final succeeded = submit('succeeded');
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    encoder.calls.first.completeError(StateError('simulated encoder failure'));
    await expectLater(failed.completed, throwsStateError);
    while (encoder.calls.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    encoder.calls.last.complete(_jpegResult(Uint8List(64)));

    final artifact = await succeeded.completed;
    expect(artifact.status, GeneratedImageStorageStatus.jpegSaved);
    expect(await File(artifact.currentFile!.path).exists(), isTrue);
    expect(failed.artifact.status, GeneratedImageStorageStatus.failed);
    expect(failed.artifact.currentFile?.mediaType, 'image/png');
  });

  test('retaining PNG publishes both formats with one stem in the same folder',
      () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-both-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final source = _opaquePng();
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async => session,
    );

    final submission = storage.submit(GeneratedImageStorageRequest(
      logicalTaskId: 'retain:both',
      pngBytes: source,
      fileName: 'paired.png',
      storagePolicy: GeneratedImageStoragePolicy(
        jpegEnabled: true,
        retainOriginalPng: true,
        pngOutputDirectory: output.path,
        jpegOutputDirectory: output.path,
      ),
      metadataPolicy: const GeneratedImageMetadataPolicy(
        eraseMetadata: false,
        customMetadataEnabled: false,
        customMetadataContent: '',
      ),
    ));
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final permanentPng = File(_pathIn(output, 'paired.png'));
    expect(submission.artifact.currentFile?.path, permanentPng.absolute.path);
    expect(submission.artifact.currentFile?.isPermanent, isTrue);
    expect(
        submission.artifact.originalPngFile?.path, permanentPng.absolute.path);
    expect(await permanentPng.readAsBytes(), source);

    encoder.calls.single.complete(_jpegResult(Uint8List(64)));
    final artifact = await submission.completed;
    final permanentJpeg = File(_pathIn(output, 'paired.jpg'));

    expect(artifact.currentFile?.path, permanentJpeg.absolute.path);
    expect(artifact.originalPngFile?.path, permanentPng.absolute.path);
    expect(
      artifact.permanentFiles.map((file) => file.mediaType),
      ['image/jpeg', 'image/png'],
    );
    expect(await permanentPng.exists(), isTrue);
    expect(await permanentJpeg.exists(), isTrue);
    expect(session.listSync().whereType<File>(), isEmpty);
  });

  test('a truly transparent image publishes an exact permanent PNG fallback',
      () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-fallback-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final source = _opaquePng(width: 8, height: 8);
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async => session,
    );
    final submission = storage.submit(GeneratedImageStorageRequest(
      logicalTaskId: 'transparent:fallback',
      pngBytes: source,
      fileName: 'transparent.png',
      storagePolicy: GeneratedImageStoragePolicy(
        jpegEnabled: true,
        retainOriginalPng: false,
        pngOutputDirectory: '',
        jpegOutputDirectory: output.path,
      ),
      metadataPolicy: const GeneratedImageMetadataPolicy(
        eraseMetadata: false,
        customMetadataEnabled: false,
        customMetadataContent: '',
      ),
    ));
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    encoder.calls.single.complete(const GeneratedImageJpegEncodingResult(
      status: GeneratedImageJpegEncodingStatus.transparencyUnsupported,
      jpegBytes: null,
      width: 8,
      height: 8,
      hasTransparency: true,
      metadataJson: null,
    ));

    final artifact = await submission.completed;
    final fallback = File(_pathIn(output, 'transparent.png'));
    expect(artifact.status, GeneratedImageStorageStatus.pngFallbackSaved);
    expect(artifact.currentFile?.path, fallback.absolute.path);
    expect(artifact.originalPngFile?.path, fallback.absolute.path);
    expect(artifact.permanentFiles, [artifact.currentFile]);
    expect(await fallback.readAsBytes(), source);
    expect(await File(_pathIn(output, 'transparent.jpg')).exists(), isFalse);
  });

  test('concurrent jobs cannot reserve and overwrite the same resolved name',
      () async {
    final session = await Directory.systemTemp.createTemp('casrand-session-');
    final output = await Directory.systemTemp.createTemp('casrand-collision-');
    addTearDown(() async {
      if (await session.exists()) await session.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionDirectoryProvider: () async => session,
      maxConcurrentJpegJobs: 2,
    );
    final source = _opaquePng();
    GeneratedImageStorageSubmission submit(String logicalTaskId) {
      return storage.submit(GeneratedImageStorageRequest(
        logicalTaskId: logicalTaskId,
        pngBytes: source,
        fileName: 'collision.png',
        storagePolicy: GeneratedImageStoragePolicy(
          jpegEnabled: true,
          retainOriginalPng: false,
          pngOutputDirectory: '',
          jpegOutputDirectory: output.path,
        ),
        metadataPolicy: const GeneratedImageMetadataPolicy(
          eraseMetadata: false,
          customMetadataEnabled: false,
          customMetadataContent: '',
        ),
      ));
    }

    final first = submit('collision:first');
    final second = submit('collision:second');
    Future<Object> settle(GeneratedImageStorageSubmission submission) {
      return submission.completed.then<Object>(
        (artifact) => artifact,
        onError: (Object error) => error,
      );
    }

    final outcomes = Future.wait([settle(first), settle(second)]);
    for (var attempt = 0;
        attempt < 500 &&
            !(encoder.calls.length == 1 &&
                (first.artifact.status == GeneratedImageStorageStatus.failed ||
                    second.artifact.status ==
                        GeneratedImageStorageStatus.failed));
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(encoder.calls, hasLength(1));
    encoder.calls.single.complete(_jpegResult(Uint8List(64)));
    final settled = await outcomes;

    expect(settled.whereType<GeneratedImageArtifact>(), hasLength(1));
    expect(settled.whereType<FileSystemException>(), hasLength(1));
    expect(await File(_pathIn(output, 'collision.jpg')).readAsBytes(),
        Uint8List(64));
  });
  test('storage closes an empty queue and rejects submissions afterwards',
      () async {
    final root = await Directory.systemTemp.createTemp('casrand-lifecycle-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      sessionRootDirectoryProvider: () async => root,
      sessionDirectoryProvider: () async =>
          Directory(_pathIn(root, 'session-current')),
    );

    await storage.close();
    expect(storage.isClosed, isTrue);
    final rejected = storage.submit(_jpegRequest('after-close', root.path));

    await expectLater(rejected.completed,
        throwsA(isA<GeneratedImageStorageAbandonedException>()));
    expect(rejected.artifact.status, GeneratedImageStorageStatus.abandoned);
  });

  test('close wait drains queued work before cleaning the owned session',
      () async {
    final root = await Directory.systemTemp.createTemp('casrand-lifecycle-');
    final output =
        await Directory.systemTemp.createTemp('casrand-lifecycle-output-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final current = Directory(_pathIn(root, 'session-current'));
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionRootDirectoryProvider: () async => root,
      sessionDirectoryProvider: () async => current,
      maxConcurrentJpegJobs: 1,
      maxPendingJpegJobs: 4,
    );
    final first = storage.submit(_jpegRequest('wait-first', output.path));
    final second = storage.submit(_jpegRequest('wait-second', output.path));
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    var closed = false;
    final closeFuture = storage.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    encoder.calls.first.complete(_jpegResult(Uint8List(64)));
    while (encoder.calls.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    encoder.calls.last.complete(_jpegResult(Uint8List(64)));
    await closeFuture;
    expect(closed, isTrue);
    expect(first.artifact.status, GeneratedImageStorageStatus.jpegSaved);
    expect(second.artifact.status, GeneratedImageStorageStatus.jpegSaved);
    expect(await current.exists(), isFalse);
  });

  test('close abandon settles pending and active jobs without promoting files',
      () async {
    final root = await Directory.systemTemp.createTemp('casrand-lifecycle-');
    final output =
        await Directory.systemTemp.createTemp('casrand-lifecycle-output-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final current = Directory(_pathIn(root, 'session-current'));
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionRootDirectoryProvider: () async => root,
      sessionDirectoryProvider: () async => current,
      maxConcurrentJpegJobs: 1,
      maxPendingJpegJobs: 4,
    );
    final active = storage.submit(_jpegRequest('abandon-active', output.path));
    final pending =
        storage.submit(_jpegRequest('abandon-pending', output.path));
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await storage.close(abandon: true).timeout(const Duration(seconds: 1));
    await expectLater(active.completed,
        throwsA(isA<GeneratedImageStorageAbandonedException>()));
    await expectLater(pending.completed,
        throwsA(isA<GeneratedImageStorageAbandonedException>()));
    expect(active.artifact.status, GeneratedImageStorageStatus.abandoned);
    expect(pending.artifact.status, GeneratedImageStorageStatus.abandoned);
    encoder.calls.first.complete(_jpegResult(Uint8List(64)));
    await Future<void>.delayed(Duration.zero);
    expect(await File(_pathIn(output, 'abandon-active.jpg')).exists(), isFalse);
    expect(
        await File(_pathIn(output, 'abandon-pending.jpg')).exists(), isFalse);
    expect(await current.exists(), isFalse);
  });

  test('abandon keeps an already published permanent file', () async {
    final root = await Directory.systemTemp.createTemp('casrand-lifecycle-');
    final output =
        await Directory.systemTemp.createTemp('casrand-lifecycle-output-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await output.exists()) await output.delete(recursive: true);
    });
    final encoder = _ControlledJpegEncoder();
    final current = Directory(_pathIn(root, 'session-current'));
    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      jpegEncoder: encoder,
      sessionRootDirectoryProvider: () async => root,
      sessionDirectoryProvider: () async => current,
      maxConcurrentJpegJobs: 1,
      maxPendingJpegJobs: 4,
    );
    final finished = storage.submit(_jpegRequest('published', output.path));
    while (encoder.calls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    encoder.calls.first.complete(_jpegResult(Uint8List(64)));
    await finished.completed;
    final published = File(_pathIn(output, 'published.jpg'));
    expect(await published.exists(), isTrue);

    final unfinished = storage.submit(_jpegRequest('unfinished', output.path));
    while (encoder.calls.length < 2) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await storage.close(abandon: true);
    expect(await published.exists(), isTrue);
    expect(unfinished.artifact.status, GeneratedImageStorageStatus.abandoned);
    encoder.calls.last.complete(_jpegResult(Uint8List(64)));
  });

  test(
      'startup cleanup removes only marked stale sessions and preserves current',
      () async {
    final root =
        await Directory.systemTemp.createTemp('casrand-lifecycle-root-');
    final stale = Directory(_pathIn(root, 'session-stale'));
    final current = Directory(_pathIn(root, 'session-current'));
    final unmarked = Directory(_pathIn(root, 'session-unmarked'));
    final outside =
        await Directory.systemTemp.createTemp('casrand-lifecycle-outside-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await stale.create(recursive: true);
    await unmarked.create(recursive: true);
    await File(_pathIn(stale, '.casrand-session')).writeAsString(
      'CasRand Forge generated-image session\nlaunch=old\n',
    );
    await File(_pathIn(stale, 'stale.png')).writeAsBytes([1, 2, 3]);
    await File(_pathIn(unmarked, 'keep.png')).writeAsBytes([4, 5, 6]);
    await File(_pathIn(outside, '.casrand-session')).writeAsString(
      'CasRand Forge generated-image session\nlaunch=outside\n',
    );

    final storage = GeneratedImageStorageService(
      desktopJpegSupported: true,
      sessionRootDirectoryProvider: () async => root,
      sessionDirectoryProvider: () async => current,
    );
    await storage.cleanupStaleSessions();

    expect(await stale.exists(), isFalse);
    expect(await current.exists(), isFalse);
    expect(await unmarked.exists(), isTrue);
    expect(await outside.exists(), isTrue);

    await storage.initialize();
    expect(await current.exists(), isTrue);
  });
}
