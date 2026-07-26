import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:image_size_getter/image_size_getter.dart';

/// A single freehand stroke in the inpainting mask editor.
/// Points are stored in image-pixel coordinates.
class MaskStroke {
  final bool isErase;
  final double brushSize;
  final List<Offset> points;

  const MaskStroke({
    required this.isErase,
    required this.brushSize,
    required this.points,
  });
}

class I2IConfig with ChangeNotifier {
  // Base image
  Uint8List? _imageBytes;
  String? _imageB64Cache;
  int width = 0;
  int height = 0;

  double strength;
  double noise;

  // Inpainting mask: PNG (white = repaint, black = keep), same size as image.
  Uint8List? _maskBytes;
  String? _maskB64Cache;

  // Editor strokes kept so the mask stays editable after closing the editor.
  List<MaskStroke> maskStrokes = [];

  bool addOriginalImage;
  bool autocropEnabled;

  /// Increment on every image/mask change so cached request plans invalidate.
  int revision = 0;

  I2IConfig({
    String? imageB64,
    this.strength = 0.7,
    this.noise = 0,
    this.addOriginalImage = true,
    this.autocropEnabled = true,
  }) {
    if (imageB64 != null) {
      setImage(base64Decode(imageB64));
    }
  }

  Uint8List? get imageBytes => _imageBytes;
  Uint8List? get maskBytes => _maskBytes;

  bool get hasImage => _imageBytes != null;
  bool get hasMask => _maskBytes != null;

  String? get imageB64 {
    if (_imageBytes == null) return null;
    _imageB64Cache ??= base64Encode(_imageBytes!);
    return _imageB64Cache;
  }

  set imageB64(String? value) {
    if (value == null) {
      removeImage();
      return;
    }
    setImage(base64Decode(value));
  }

  String? get maskB64 {
    if (_maskBytes == null) return null;
    _maskB64Cache ??= base64Encode(_maskBytes!);
    return _maskB64Cache;
  }

  void setImage(Uint8List bytes) {
    final size = ImageSizeGetter.getSize(MemoryInput(bytes));
    width = size.width;
    height = size.height;
    _imageBytes = bytes;
    _imageB64Cache = null;
    // Mask coordinates are bound to the previous image; drop them.
    _maskBytes = null;
    _maskB64Cache = null;
    maskStrokes = [];
    revision++;
    notifyListeners();
  }

  void removeImage() {
    _imageBytes = null;
    _imageB64Cache = null;
    _maskBytes = null;
    _maskB64Cache = null;
    maskStrokes = [];
    width = 0;
    height = 0;
    revision++;
    notifyListeners();
  }

  void setMask(Uint8List? pngBytes, List<MaskStroke> strokes) {
    _maskBytes = pngBytes;
    _maskB64Cache = null;
    maskStrokes = strokes;
    revision++;
    notifyListeners();
  }

  void removeMask() {
    _maskBytes = null;
    _maskB64Cache = null;
    maskStrokes = [];
    revision++;
    notifyListeners();
  }

  void setStrength(double value) {
    strength = value;
    revision++;
    notifyListeners();
  }

  void setNoise(double value) {
    noise = value;
    revision++;
    notifyListeners();
  }

  void setAddOriginalImage(bool value) {
    addOriginalImage = value;
    revision++;
    notifyListeners();
  }

  void setAutocropEnabled(bool value) {
    autocropEnabled = value;
    revision++;
    notifyListeners();
  }
}
