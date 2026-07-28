import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:image_size_getter/image_size_getter.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart'
    show CropRect, defaultContextPx, normalizeContextPx;
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';

/// A single freehand stroke in the inpainting mask editor.
/// Points are stored in image-pixel coordinates. [brushSize] uses NovelAI's
/// mask-layer pixels: one brush pixel covers an 8x8 image-pixel cell.
enum MaskBrushShape { circle, square }

class MaskStroke {
  final bool isErase;
  final double brushSize;
  final MaskBrushShape shape;
  final List<Offset> points;

  const MaskStroke({
    required this.isErase,
    required this.brushSize,
    this.shape = MaskBrushShape.circle,
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
  bool useRandomSeed;
  GenerationSize requestSize;
  I2iSizeMode sizeMode;

  // Inpainting mask: PNG (white = repaint, black = keep), same size as image.
  Uint8List? _maskBytes;
  String? _maskB64Cache;

  // Imported/raster mask before editable brush and eraser strokes are applied.
  Uint8List? _maskBaseBytes;

  // Editor strokes kept so the mask stays editable after closing the editor.
  List<MaskStroke> maskStrokes = [];

  bool addOriginalImage;
  bool autocropEnabled;
  int contextPx;

  /// Hand-drawn focus-inpainting frame in image pixels. When set, it replaces
  /// Autocrop's automatically chosen outer frame.
  CropRect? manualFocusFrame;

  /// Increment on every image/mask change so cached request plans invalidate.
  int revision = 0;

  /// Increment only when the expensive image/mask preparation or focus
  /// geometry changes. Strength and other light request parameters do not
  /// invalidate decoded images or Autocrop tiles.
  int planRevision = 0;

  I2IConfig({
    String? imageB64,
    this.strength = 0.7,
    this.noise = 0,
    this.useRandomSeed = false,
    this.requestSize = const GenerationSize(width: 832, height: 1216),
    this.sizeMode = I2iSizeMode.automatic,
    this.addOriginalImage = false,
    this.autocropEnabled = true,
    this.contextPx = defaultContextPx,
  }) {
    if (imageB64 != null) {
      setImage(base64Decode(imageB64));
    }
  }

  Uint8List? get imageBytes => _imageBytes;
  Uint8List? get maskBytes => _maskBytes;
  Uint8List? get maskBaseBytes => _maskBaseBytes;

  bool get hasImage => _imageBytes != null;
  bool get hasMask => _maskBytes != null;

  /// Whether generation should use the inpainting path. NovelAI Focused
  /// Inpainting treats a manual frame with no painted mask as a request to
  /// repaint the whole inner region of that frame.
  bool get hasInpaintSelection => hasMask || manualFocusFrame != null;

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
    // Mask and focus frame coordinates are bound to the previous image.
    _maskBytes = null;
    _maskB64Cache = null;
    _maskBaseBytes = null;
    maskStrokes = [];
    manualFocusFrame = null;
    sizeMode = I2iSizeMode.automatic;
    requestSize = automaticI2iRequestSize(width, height);
    revision++;
    planRevision++;
    notifyListeners();
  }

  void removeImage() {
    _imageBytes = null;
    _imageB64Cache = null;
    _maskBytes = null;
    _maskB64Cache = null;
    _maskBaseBytes = null;
    maskStrokes = [];
    manualFocusFrame = null;
    width = 0;
    height = 0;
    revision++;
    planRevision++;
    notifyListeners();
  }

  void setMask(
    Uint8List? pngBytes,
    List<MaskStroke> strokes, {
    Uint8List? baseMaskBytes,
    CropRect? focusFrame,
    int? minimumContextPx,
  }) {
    _maskBytes = pngBytes;
    _maskB64Cache = null;
    _maskBaseBytes = baseMaskBytes ??
        (pngBytes != null && strokes.isEmpty ? pngBytes : null);
    maskStrokes = strokes;
    manualFocusFrame = focusFrame;
    if (minimumContextPx != null) {
      contextPx = normalizeContextPx(minimumContextPx);
    }
    revision++;
    planRevision++;
    notifyListeners();
  }

  void removeMask() {
    _maskBytes = null;
    _maskB64Cache = null;
    _maskBaseBytes = null;
    maskStrokes = [];
    manualFocusFrame = null;
    revision++;
    planRevision++;
    notifyListeners();
  }

  void setStrength(double value) {
    if (strength == value) return;
    strength = value;
    revision++;
    notifyListeners();
  }

  void setNoise(double value) {
    if (noise == value) return;
    noise = value;
    revision++;
    notifyListeners();
  }

  void setUseRandomSeed(bool value) {
    if (useRandomSeed == value) return;
    useRandomSeed = value;
    revision++;
    notifyListeners();
  }

  void setRequestSize(GenerationSize value, {I2iSizeMode? mode}) {
    final nextMode = mode ?? sizeMode;
    if (requestSize == value && sizeMode == nextMode) return;
    requestSize = value;
    sizeMode = nextMode;
    revision++;
    planRevision++;
    notifyListeners();
  }

  void setAddOriginalImage(bool value) {
    if (addOriginalImage == value) return;
    addOriginalImage = value;
    revision++;
    notifyListeners();
  }

  void setAutocropEnabled(bool value) {
    if (autocropEnabled == value) return;
    autocropEnabled = value;
    revision++;
    planRevision++;
    notifyListeners();
  }

  void setManualFocusFrame(CropRect? value) {
    if (manualFocusFrame == value) return;
    manualFocusFrame = value;
    revision++;
    planRevision++;
    notifyListeners();
  }

  void setContextPx(int value) {
    final normalized = normalizeContextPx(value);
    if (contextPx == normalized) return;
    contextPx = normalized;
    revision++;
    planRevision++;
    notifyListeners();
  }
}
