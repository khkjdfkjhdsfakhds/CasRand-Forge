import 'package:flutter/foundation.dart';
import 'package:image_size_getter/image_size_getter.dart';

/// Header-only dimensions in the same orientation as the displayed image.
/// JPEG EXIF orientations 5–8 swap axes; no full pixel decode is needed.
Size displayedImageSize(Uint8List bytes) {
  final size = ImageSizeGetter.getSize(MemoryInput(bytes));
  return size.needRotate ? Size(size.height, size.width) : size;
}
