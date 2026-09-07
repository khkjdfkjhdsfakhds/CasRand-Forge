import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

enum PreciseReferenceType {
  character,
  style,
  characterAndStyle,
}

extension PreciseReferenceTypeLabel on PreciseReferenceType {
  String get displayName {
    switch (this) {
      case PreciseReferenceType.character:
        return 'Character Reference';
      case PreciseReferenceType.style:
        return 'Style Reference';
      case PreciseReferenceType.characterAndStyle:
        return 'Character & Style Reference';
    }
  }

  String get payloadCaption {
    switch (this) {
      case PreciseReferenceType.character:
        return 'character';
      case PreciseReferenceType.style:
        return 'style';
      case PreciseReferenceType.characterAndStyle:
        return 'character&style';
    }
  }
}

class PreciseReferenceConfig {
  static const MethodChannel _imageProcessorChannel =
      MethodChannel('casrand_forge/precise_reference');

  static const List<({int width, int height})> officialCanvasSizes = [
    (width: 1024, height: 1536),
    (width: 1472, height: 1472),
    (width: 1536, height: 1024),
  ];

  String imageB64;
  String fileName;
  PreciseReferenceType type;
  double strength;
  double fidelity;
  bool enabled;

  PreciseReferenceConfig({
    required this.imageB64,
    required this.fileName,
    this.type = PreciseReferenceType.characterAndStyle,
    double strength = 1.0,
    double fidelity = 1.0,
    this.enabled = true,
  })  : strength = strength.clamp(0.0, 1.0),
        fidelity = fidelity.clamp(0.0, 1.0);

  static Future<PreciseReferenceConfig> fromBytes(
    Uint8List imageBytes,
    String fileName, {
    PreciseReferenceType type = PreciseReferenceType.characterAndStyle,
    double strength = 1.0,
    double fidelity = 1.0,
  }) async {
    final processedImageBytes = await _processImageBytes(imageBytes);
    return PreciseReferenceConfig(
      imageB64: base64Encode(processedImageBytes),
      fileName: fileName,
      type: type,
      strength: strength,
      fidelity: fidelity,
    );
  }

  Uint8List get imageBytes => base64Decode(imageB64);

  static Future<Uint8List> _processImageBytes(Uint8List imageBytes) async {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final prepared = await compute(_prepareMacReference, imageBytes);
      final processedPixels =
          await _imageProcessorChannel.invokeMethod<Uint8List>(
        'processImage',
        {
          'sourcePixels': prepared['sourcePixels'],
          'sourceWidth': prepared['sourceWidth'],
          'sourceHeight': prepared['sourceHeight'],
          'targetWidth': prepared['targetWidth'],
          'targetHeight': prepared['targetHeight'],
          'drawWidth': prepared['drawWidth'],
          'drawHeight': prepared['drawHeight'],
          'offsetX': prepared['offsetX'],
          'offsetY': prepared['offsetY'],
        },
      );
      if (processedPixels == null) {
        throw StateError(
            'macOS Precise Reference processing returned no data.');
      }
      return compute(
        _encodeMacReference,
        <String, Object>{
          'pixels': processedPixels,
          'width': prepared['targetWidth']!,
          'height': prepared['targetHeight']!,
        },
      );
    }
    return compute(_processDartReference, imageBytes);
  }

  static ({int width, int height}) _selectCanvasSize(int width, int height) {
    final sourceRatio = width / height;
    return officialCanvasSizes.reduce((best, candidate) {
      final bestDistance = (sourceRatio - best.width / best.height).abs();
      final candidateDistance =
          (sourceRatio - candidate.width / candidate.height).abs();
      return candidateDistance < bestDistance ? candidate : best;
    });
  }
}

Map<String, Object> _prepareMacReference(Uint8List imageBytes) {
  final sourceImage = _decodeReference(imageBytes);
  final geometry = _referenceGeometry(sourceImage.width, sourceImage.height);
  return <String, Object>{
    'sourcePixels': sourceImage.getBytes(order: img.ChannelOrder.rgba),
    'sourceWidth': sourceImage.width,
    'sourceHeight': sourceImage.height,
    ...geometry,
  };
}

Uint8List _encodeMacReference(Map<String, Object> values) {
  final pixels = values['pixels']! as Uint8List;
  final image = img.Image.fromBytes(
    width: values['width']! as int,
    height: values['height']! as int,
    bytes: pixels.buffer,
    bytesOffset: pixels.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _processDartReference(Uint8List imageBytes) {
  final sourceImage = _decodeReference(imageBytes);
  final geometry = _referenceGeometry(sourceImage.width, sourceImage.height);
  final targetWidth = geometry['targetWidth']! as int;
  final targetHeight = geometry['targetHeight']! as int;
  final drawWidth = geometry['drawWidth']! as int;
  final drawHeight = geometry['drawHeight']! as int;
  final resizedImage = img.copyResize(
    sourceImage,
    width: drawWidth,
    height: drawHeight,
    interpolation: img.Interpolation.cubic,
  );
  final canvas = img.Image(
    width: targetWidth,
    height: targetHeight,
    numChannels: 3,
  );
  img.fill(canvas, color: img.ColorRgb8(0, 0, 0));
  img.compositeImage(
    canvas,
    resizedImage,
    dstX: ((targetWidth - drawWidth) / 2).round(),
    dstY: ((targetHeight - drawHeight) / 2).round(),
  );
  return Uint8List.fromList(img.encodePng(canvas));
}

img.Image _decodeReference(Uint8List imageBytes) {
  final sourceImage = img.decodeImage(imageBytes);
  if (sourceImage == null) {
    throw const FormatException('Unsupported Precise Reference image file.');
  }
  return sourceImage;
}

Map<String, Object> _referenceGeometry(int sourceWidth, int sourceHeight) {
  final targetSize =
      PreciseReferenceConfig._selectCanvasSize(sourceWidth, sourceHeight);
  final sourceRatio = sourceWidth / sourceHeight;
  final targetRatio = targetSize.width / targetSize.height;
  final drawWidth = sourceRatio > targetRatio
      ? targetSize.width
      : (targetSize.height * sourceRatio).round();
  final drawHeight = sourceRatio > targetRatio
      ? (targetSize.width / sourceRatio).round()
      : targetSize.height;
  return <String, Object>{
    'targetWidth': targetSize.width,
    'targetHeight': targetSize.height,
    'drawWidth': drawWidth,
    'drawHeight': drawHeight,
    'offsetX': (targetSize.width - drawWidth) / 2,
    'offsetY': (targetSize.height - drawHeight) / 2,
  };
}
