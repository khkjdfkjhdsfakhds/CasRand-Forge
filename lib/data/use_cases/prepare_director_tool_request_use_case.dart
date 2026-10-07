import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/generation_size.dart';

const int directorToolMaximumPixels = 3145728 - 2000;
const int directorToolMinimumResizePixels = 1011712;
const int directorToolTargetPixels = 1048576;

class PreparedDirectorToolImage {
  final String imageB64;
  final int width;
  final int height;

  /// Prepared PNG bytes. Multipart relays upload the file itself instead of
  /// the base64 copy they expect inside a JSON body.
  final Uint8List? imageBytes;

  const PreparedDirectorToolImage({
    required this.imageB64,
    required this.width,
    required this.height,
    this.imageBytes,
  });

  /// Prepared bytes, decoding the base64 copy only when a caller did not
  /// provide them.
  Uint8List get preparedBytes => imageBytes ?? base64Decode(imageB64);
}

GenerationSize directorToolRequestSize(int width, int height) {
  if (width <= 0 || height <= 0) {
    throw const FormatException('Director Tools image dimensions are invalid.');
  }
  final pixels = width * height;
  if (pixels > directorToolMaximumPixels) {
    return _scaledDirectorToolSize(
      width,
      height,
      directorToolMaximumPixels,
    );
  }
  if (pixels < directorToolMinimumResizePixels) {
    return _scaledDirectorToolSize(width, height, directorToolTargetPixels);
  }
  return GenerationSize(width: width, height: height);
}

GenerationSize _scaledDirectorToolSize(int width, int height, int pixels) {
  final scale = sqrt(pixels / (width * height));
  return GenerationSize(
    width: max(1, (width * scale).floor()),
    height: max(1, (height * scale).floor()),
  );
}

Map<String, Object> _prepareDirectorToolImage(Map<String, Object> input) {
  final bytes = input['imageBytes']! as Uint8List;
  final width = input['width']! as int;
  final height = input['height']! as int;
  final target = directorToolRequestSize(width, height);

  if (target.width == width && target.height == height) {
    return <String, Object>{
      'imageB64': base64Encode(bytes),
      'width': width,
      'height': height,
      'imageBytes': bytes,
    };
  }

  final source = img.decodeImage(bytes);
  if (source == null) {
    throw const FormatException('Director Tools image could not be decoded.');
  }
  final resized = img.copyResize(
    source,
    width: target.width,
    height: target.height,
    interpolation: img.Interpolation.linear,
  );
  final prepared = img.encodePng(resized, level: 1);
  return <String, Object>{
    'imageB64': base64Encode(prepared),
    'width': target.width,
    'height': target.height,
    'imageBytes': Uint8List.fromList(prepared),
  };
}

class PrepareDirectorToolRequestUseCase {
  const PrepareDirectorToolRequestUseCase();

  Future<PreparedDirectorToolImage> call({
    required Uint8List imageBytes,
    required int width,
    required int height,
  }) async {
    final result = await compute(_prepareDirectorToolImage, <String, Object>{
      'imageBytes': imageBytes,
      'width': width,
      'height': height,
    });
    return PreparedDirectorToolImage(
      imageB64: result['imageB64']! as String,
      width: result['width']! as int,
      height: result['height']! as int,
      imageBytes: result['imageBytes'] as Uint8List?,
    );
  }
}
