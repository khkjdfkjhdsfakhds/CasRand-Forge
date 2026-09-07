import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

Uint8List makeTestPng({int width = 2, int height = 2}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(40, 90, 140));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List embedVibeEncodingInPng(
  Uint8List pngBytes,
  String encoding,
) {
  const keyword = 'NovelAI_Vibe_Encoding_Base64';
  final data = Uint8List.fromList([
    ...utf8.encode(keyword),
    0, // Keyword terminator.
    0, // Compression flag: uncompressed.
    0, // Compression method.
    0, // Empty language tag.
    0, // Empty translated keyword.
    ...utf8.encode(encoding),
  ]);
  final type = ascii.encode('iTXt');
  final crcInput = <int>[...type, ...data];
  final chunk = BytesBuilder(copy: false)
    ..add(_uint32(data.length))
    ..add(type)
    ..add(data)
    ..add(_uint32(getCrc32(crcInput)));

  // A valid PNG always ends with the 12-byte IEND chunk. Insert the iTXt
  // immediately before it so no user/private fixture is needed in tests.
  final iendOffset = pngBytes.length - 12;
  return Uint8List.fromList([
    ...pngBytes.sublist(0, iendOffset),
    ...chunk.takeBytes(),
    ...pngBytes.sublist(iendOffset),
  ]);
}

Uint8List _uint32(int value) {
  final data = ByteData(4)..setUint32(0, value & 0xFFFFFFFF, Endian.big);
  return data.buffer.asUint8List();
}
