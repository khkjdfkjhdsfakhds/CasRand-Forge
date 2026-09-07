import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'image_storage_recovery_test.dart' as fixture;

void main() {
  test('JPEG new-request publication preserves an existing dangling symlink',
      () async {
    final root =
        await Directory.systemTemp.createTemp('casrand-crossreview-link-');
    final link = Link('${root.path}/PAID_RESULT.png');
    await link.create('${root.path}/external-missing-target');
    final storage = GeneratedImageStorageService(
        desktopJpegSupported: true,
        jpegEncoder:
            fixture.FlakyEncoder(Uint8List.fromList([1, 2]), failOnce: true));
    try {
      try {
        await storage
            .submit(fixture.request(fixture.fixturePng(), root.path,
                jpeg: true, retain: true))
            .completed;
      } catch (_) {}
      expect(await FileSystemEntity.type(link.path, followLinks: false),
          FileSystemEntityType.link);
    } finally {
      await storage.close();
      await root.delete(recursive: true);
    }
  });
  test('PNG publication preserves an unrelated pre-existing same-name image',
      () async {
    final root =
        await Directory.systemTemp.createTemp('casrand-crossreview-png-');
    final file = File('${root.path}/PAID_RESULT.png');
    final original = Uint8List.fromList([91, 81, 71]);
    await file.writeAsBytes(original);
    final storage = GeneratedImageStorageService(desktopJpegSupported: true);
    try {
      try {
        await storage
            .submit(fixture.request(fixture.fixturePng(), root.path))
            .completed;
      } catch (_) {}
      expect(await file.readAsBytes(), original);
    } finally {
      await storage.close();
      await root.delete(recursive: true);
    }
  });
  test('same PNG request reuses its unchanged successful publication',
      () async {
    final root = await Directory.systemTemp.createTemp('casrand-png-receipt-');
    final storage = GeneratedImageStorageService(desktopJpegSupported: true);
    try {
      final request = fixture.request(fixture.fixturePng(), root.path);
      final first = await storage.submit(request).completed;
      final file = File(first.currentFile!.path);
      final before = await file.stat();
      final again = await storage.submit(request).completed;
      expect(again.isDurablySaved, isTrue);
      expect(again.currentFile!.path, first.currentFile!.path);
      expect((await file.stat()).modified, before.modified);
      expect(await file.readAsBytes(), request.pngBytes);
    } finally {
      await storage.close();
      await root.delete(recursive: true);
    }
  });
  for (final mode in ['changed', 'new-request', 'symlink']) {
    test('PNG receipt never adopts unrelated data: $mode', () async {
      final root =
          await Directory.systemTemp.createTemp('casrand-png-receipt-guard-');
      final storage = GeneratedImageStorageService(desktopJpegSupported: true);
      try {
        final request = fixture.request(fixture.fixturePng(), root.path);
        final first = await storage.submit(request).completed;
        final file = File(first.currentFile!.path);
        final replacement = Uint8List.fromList([91, 81, 71]);
        if (mode == 'changed') await file.writeAsBytes(replacement);
        if (mode == 'symlink') {
          await file.delete();
          await Link(file.path).create('${root.path}/missing-target');
        }
        final next = mode == 'new-request'
            ? fixture.request(request.pngBytes, root.path)
            : request;
        await expectLater(storage.submit(next).completed,
            throwsA(isA<FileSystemException>()));
        if (mode == 'changed') expect(await file.readAsBytes(), replacement);
        if (mode == 'new-request') {
          expect(await file.readAsBytes(), request.pngBytes);
        }
        if (mode == 'symlink') {
          expect(await FileSystemEntity.type(file.path, followLinks: false),
              FileSystemEntityType.link);
        }
      } finally {
        await storage.close();
        await root.delete(recursive: true);
      }
    });
  }
  test('separate PNG storage services cannot both publish to the same name',
      () async {
    final root =
        await Directory.systemTemp.createTemp('casrand-png-collision-');
    final first = GeneratedImageStorageService(desktopJpegSupported: true);
    final second = GeneratedImageStorageService(desktopJpegSupported: true);
    try {
      final request = fixture.request(fixture.fixturePng(), root.path);
      final outcomes = await Future.wait([
        first
            .submit(request)
            .completed
            .then((_) => true, onError: (Object e) => false),
        second
            .submit(request)
            .completed
            .then((_) => true, onError: (Object e) => false),
      ]);
      expect(outcomes.where((saved) => saved), hasLength(1));
      expect(await File('${root.path}/PAID_RESULT.png').readAsBytes(),
          request.pngBytes);
      expect(await root.list().length, 1);
    } finally {
      await first.close();
      await second.close();
      await root.delete(recursive: true);
    }
  });
}
