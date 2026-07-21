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
    final sourceImage = img.decodeImage(imageBytes);
    if (sourceImage == null) {
      throw const FormatException('Unsupported Precise Reference image file.');
    }
    final targetSize = _selectCanvasSize(sourceImage.width, sourceImage.height);
    final sourceRatio = sourceImage.width / sourceImage.height;
    final targetRatio = targetSize.width / targetSize.height;
    final resizedWidth = sourceRatio > targetRatio
        ? targetSize.width
        : (targetSize.height * sourceRatio).round();
    final resizedHeight = sourceRatio > targetRatio
        ? (targetSize.width / sourceRatio).round()
        : targetSize.height;

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final processedPixels =
          await _imageProcessorChannel.invokeMethod<Uint8List>(
        'processImage',
        {
          'sourcePixels': sourceImage.getBytes(order: img.ChannelOrder.rgba),
          'sourceWidth': sourceImage.width,
          'sourceHeight': sourceImage.height,
          'targetWidth': targetSize.width,
          'targetHeight': targetSize.height,
          'drawWidth': resizedWidth,
          'drawHeight': resizedHeight,
          'offsetX': (targetSize.width - resizedWidth) / 2,
          'offsetY': (targetSize.height - resizedHeight) / 2,
        },
      );
      if (processedPixels == null) {
        throw StateError(
            'macOS Precise Reference processing returned no data.');
      }
      final processedImage = img.Image.fromBytes(
        width: targetSize.width,
        height: targetSize.height,
        bytes: processedPixels.buffer,
        bytesOffset: processedPixels.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      return Uint8List.fromList(img.encodePng(processedImage));
    }

    final resizedImage = img.copyResize(
      sourceImage,
      width: resizedWidth,
      height: resizedHeight,
      interpolation: img.Interpolation.cubic,
    );
    final canvas = img.Image(
      width: targetSize.width,
      height: targetSize.height,
      numChannels: 3,
    );
    img.fill(canvas, color: img.ColorRgb8(0, 0, 0));
    img.compositeImage(
      canvas,
      resizedImage,
      dstX: ((targetSize.width - resizedWidth) / 2).round(),
      dstY: ((targetSize.height - resizedHeight) / 2).round(),
    );
    return Uint8List.fromList(img.encodePng(canvas));
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
