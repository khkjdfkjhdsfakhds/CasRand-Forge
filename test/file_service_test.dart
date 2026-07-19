import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/services/file_service.dart';

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
}
