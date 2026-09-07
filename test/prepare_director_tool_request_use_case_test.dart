import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/use_cases/prepare_director_tool_request_use_case.dart';

void main() {
  test('website sizing scales a 2048 square source down to 1773 square', () {
    final size = directorToolRequestSize(2048, 2048);

    expect(size.width, 1773);
    expect(size.height, 1773);
  });

  test('preparation resizes small sources and emits matching PNG bytes',
      () async {
    final source = img.Image(width: 64, height: 64, numChannels: 3);
    img.fill(source, color: img.ColorRgb8(20, 80, 140));
    final bytes = Uint8List.fromList(img.encodePng(source));

    final prepared = await const PrepareDirectorToolRequestUseCase()(
      imageBytes: bytes,
      width: source.width,
      height: source.height,
    );

    expect(prepared.width, 1024);
    expect(prepared.height, 1024);
    final decoded = img.decodePng(base64Decode(prepared.imageB64));
    expect(decoded, isNotNull);
    expect(decoded!.width, 1024);
    expect(decoded.height, 1024);
  });
}
