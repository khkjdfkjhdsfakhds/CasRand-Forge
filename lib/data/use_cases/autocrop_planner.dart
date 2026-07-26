import 'dart:math';
import 'dart:typed_data';

/// Automatic focus-inpainting planner.
///
/// Given the inpainting mask, picks one generation window centered on the
/// mask's bounding box and pulled as large as the request-area cap allows,
/// so the masked region is repainted at the highest possible effective
/// resolution. Mirrors the behaviour of the NovelAI relay implementation:
/// masks are quantized to the server's 8-px cells, request sizes are
/// 64-aligned within [64, 1728], and windows may overhang the image edge by
/// up to 32 px so 64-alignment stays feasible on arbitrary image sizes.
const int maskCellSize = 8;
const int sizeStep = 64;
const int minRequestSide = 64;
const int maxRequestSide = 1728;
const int windowOverhang = 32;

/// Area caps matching NovelAI's size tiers.
const int areaCapNormal = 1024 * 1024;
const int areaCapLarge = 1472 * 1472;
const int areaCapWallpaper = 1728 * 1728;

/// Candidate aspect ratios (NovelAI "normal" presets) used to shape windows.
const List<Point<int>> aspectCandidates = [
  Point(1024, 1024),
  Point(832, 1216),
  Point(1216, 832),
  Point(768, 1344),
  Point(1344, 768),
  Point(640, 1536),
  Point(1536, 640),
];

class CropRect {
  final int x;
  final int y;
  final int w;
  final int h;

  const CropRect({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  int get right => x + w;
  int get bottom => y + h;
  int get area => w * h;

  bool contains(CropRect other) {
    return x <= other.x &&
        y <= other.y &&
        right >= other.right &&
        bottom >= other.bottom;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CropRect) return false;
    return other.x == x && other.y == y && other.w == w && other.h == h;
  }

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'CropRect($x, $y, ${w}x$h)';
}

/// Mask reduced to the server's 8-px cell grid. `data[cy * width + cx]` is 1
/// when any pixel in that cell is masked.
class MaskCellGrid {
  final Uint8List data;
  final int width;
  final int height;

  const MaskCellGrid({
    required this.data,
    required this.width,
    required this.height,
  });

  bool cellAt(int cx, int cy) {
    if (cx < 0 || cy < 0 || cx >= width || cy >= height) return false;
    return data[cy * width + cx] > 0;
  }

  bool get isEmpty {
    for (final value in data) {
      if (value > 0) return false;
    }
    return true;
  }
}

class AutocropPlan {
  /// The whole image already satisfies the request constraints; send it
  /// directly and use the response as the final image.
  final bool wholeImageDirect;

  /// Generation window in image coordinates. May overhang the image bounds
  /// by up to [windowOverhang] px; the overhang is padded with black.
  final CropRect window;

  /// 64-aligned request size. Differs from the window size only on the
  /// scaled fallback path (mask too large for the area cap).
  final int requestWidth;
  final int requestHeight;

  /// Whether the window is downscaled to the request size (and the response
  /// upscaled back on composite).
  final bool scaled;

  /// Mask bounding box in image pixels.
  final CropRect maskBBox;

  const AutocropPlan({
    required this.wholeImageDirect,
    required this.window,
    required this.requestWidth,
    required this.requestHeight,
    required this.scaled,
    required this.maskBBox,
  });
}

int _snap64Floor(int value) => (value ~/ sizeStep) * sizeStep;

int _clampInt(int value, int lower, int upper) =>
    max(lower, min(upper, value));

/// Area cap for a given request size, mirroring NovelAI size tiers.
int areaCapForSize(int width, int height) {
  final area = width * height;
  if (area <= areaCapNormal) return areaCapNormal;
  if (area <= areaCapLarge) return areaCapLarge;
  return areaCapWallpaper;
}

/// Reduce a full-resolution mask to the 8-px cell grid.
/// [maskPixelAt] must return true when the mask pixel is set (white).
MaskCellGrid maskCellGridFromPixels({
  required int imageWidth,
  required int imageHeight,
  required bool Function(int x, int y) maskPixelAt,
}) {
  final cellsW = (imageWidth / maskCellSize).ceil();
  final cellsH = (imageHeight / maskCellSize).ceil();
  final data = Uint8List(cellsW * cellsH);
  for (var cy = 0; cy < cellsH; cy++) {
    final pxTop = cy * maskCellSize;
    final pxBottom = min(imageHeight, pxTop + maskCellSize);
    for (var cx = 0; cx < cellsW; cx++) {
      final pxLeft = cx * maskCellSize;
      final pxRight = min(imageWidth, pxLeft + maskCellSize);
      var found = false;
      for (var y = pxTop; y < pxBottom && !found; y++) {
        for (var x = pxLeft; x < pxRight; x++) {
          if (maskPixelAt(x, y)) {
            found = true;
            break;
          }
        }
      }
      if (found) data[cy * cellsW + cx] = 1;
    }
  }
  return MaskCellGrid(data: data, width: cellsW, height: cellsH);
}

/// Mask bounding box in image pixels, or null when the mask is empty.
CropRect? maskBBoxFromCells(
  MaskCellGrid cells,
  int imageWidth,
  int imageHeight,
) {
  var minX = cells.width;
  var minY = cells.height;
  var maxX = -1;
  var maxY = -1;
  for (var cy = 0; cy < cells.height; cy++) {
    for (var cx = 0; cx < cells.width; cx++) {
      if (cells.data[cy * cells.width + cx] == 0) continue;
      if (cx < minX) minX = cx;
      if (cx > maxX) maxX = cx;
      if (cy < minY) minY = cy;
      if (cy > maxY) maxY = cy;
    }
  }
  if (maxX < 0) return null;
  final left = min(imageWidth - 1, minX * maskCellSize);
  final top = min(imageHeight - 1, minY * maskCellSize);
  final right = min(imageWidth, (maxX + 1) * maskCellSize);
  final bottom = min(imageHeight, (maxY + 1) * maskCellSize);
  return CropRect(x: left, y: top, w: right - left, h: bottom - top);
}

/// Candidate 64-aligned window sizes for an area cap, one per aspect ratio.
List<Point<int>> candidateSizesForArea(int maxArea) {
  final result = <Point<int>>[];
  final seen = <String>{};
  for (final aspect in aspectCandidates) {
    final ratio = aspect.x / aspect.y;
    var w = _clampInt(
        _snap64Floor(sqrt(maxArea * ratio).floor()), minRequestSide, maxRequestSide);
    var h = _clampInt(
        _snap64Floor(sqrt(maxArea / ratio).floor()), minRequestSide, maxRequestSide);
    while (w * h > maxArea) {
      if (w >= h && w > minRequestSide) {
        w -= sizeStep;
      } else if (h > minRequestSide) {
        h -= sizeStep;
      } else {
        break;
      }
    }
    final key = '${w}x$h';
    if (seen.add(key)) result.add(Point(w, h));
  }
  return result;
}

/// Scale (w, h) down so its area fits the cap; snap to 64 within
/// [minRequestSide, maxRequestSide]. Ported from the relay implementation.
Point<int> requestSizeForWindow(int w, int h, int maxArea) {
  final safeW = max(1, w);
  final safeH = max(1, h);
  final cap = max(minRequestSide * minRequestSide, maxArea);
  final scale = min(1.0, sqrt(cap / (safeW * safeH)));
  var rw = _clampInt(
    (safeW * scale / sizeStep).round() * sizeStep,
    minRequestSide,
    maxRequestSide,
  );
  var rh = _clampInt(
    (safeH * scale / sizeStep).round() * sizeStep,
    minRequestSide,
    maxRequestSide,
  );
  while (rw * rh > cap) {
    if (rw >= rh && rw > minRequestSide) {
      rw -= sizeStep;
    } else if (rh > minRequestSide) {
      rh -= sizeStep;
    } else {
      break;
    }
  }
  return Point(rw, rh);
}

/// Whether the whole image can be sent as-is (no crop, no scale).
bool wholeImageFitsDirect(int width, int height, int maxArea) {
  return width >= minRequestSide &&
      height >= minRequestSide &&
      width <= maxRequestSide &&
      height <= maxRequestSide &&
      width % sizeStep == 0 &&
      height % sizeStep == 0 &&
      width * height <= maxArea;
}

int _snap8(int value) => (value / maskCellSize).round() * maskCellSize;

/// Choose the position for a window of [size] centered on [center], keeping
/// [bbox] inside the window and the window within the padded image bounds.
/// Returns null when the bbox cannot fit.
int? _placeWindowAxis({
  required int size,
  required double center,
  required int bboxStart,
  required int bboxEnd,
  required int imageSize,
}) {
  if (size < bboxEnd - bboxStart) return null;
  // Any position in [lower, upper] keeps the bbox inside the window and the
  // window within [-overhang, imageSize + overhang].
  final lower = max(-windowOverhang, bboxEnd - size);
  final upper = min(imageSize - size + windowOverhang, bboxStart);
  if (lower > upper) return null;
  final raw = _clampInt((center - size / 2).round(), lower, upper);
  return _clampInt(_snap8(raw), lower, upper);
}

/// Plan the focus window for an inpainting request.
///
/// Returns null when the mask has no cells.
AutocropPlan? planAutocrop({
  required int imageWidth,
  required int imageHeight,
  required MaskCellGrid cells,
  required int maxArea,
}) {
  final bbox = maskBBoxFromCells(cells, imageWidth, imageHeight);
  if (bbox == null) return null;
  final cap = max(minRequestSide * minRequestSide, maxArea);

  if (wholeImageFitsDirect(imageWidth, imageHeight, cap)) {
    final window = CropRect(x: 0, y: 0, w: imageWidth, h: imageHeight);
    return AutocropPlan(
      wholeImageDirect: true,
      window: window,
      requestWidth: imageWidth,
      requestHeight: imageHeight,
      scaled: false,
      maskBBox: bbox,
    );
  }

  // Preferred path: the largest candidate window (native resolution) that
  // still contains the whole mask bbox, centered on the bbox.
  final centerX = bbox.x + bbox.w / 2;
  final centerY = bbox.y + bbox.h / 2;
  final bboxAspectLog = log(max(1, bbox.w) / max(1, bbox.h));
  CropRect? best;
  var bestArea = -1;
  var bestAspectDiff = double.infinity;
  for (final size in candidateSizesForArea(cap)) {
    final x = _placeWindowAxis(
      size: size.x,
      center: centerX,
      bboxStart: bbox.x,
      bboxEnd: bbox.right,
      imageSize: imageWidth,
    );
    final y = _placeWindowAxis(
      size: size.y,
      center: centerY,
      bboxStart: bbox.y,
      bboxEnd: bbox.bottom,
      imageSize: imageHeight,
    );
    if (x == null || y == null) continue;
    final rect = CropRect(x: x, y: y, w: size.x, h: size.y);
    if (!rect.contains(bbox)) continue;
    final aspectDiff = (log(size.x / size.y) - bboxAspectLog).abs();
    if (rect.area > bestArea ||
        (rect.area == bestArea && aspectDiff < bestAspectDiff)) {
      best = rect;
      bestArea = rect.area;
      bestAspectDiff = aspectDiff;
    }
  }
  if (best != null) {
    return AutocropPlan(
      wholeImageDirect: false,
      window: best,
      requestWidth: best.w,
      requestHeight: best.h,
      scaled: false,
      maskBBox: bbox,
    );
  }

  // Fallback: mask too large for a native window. Expand the bbox by
  // sqrt(2.4) per axis (clamped to the image), then scale the window down to
  // the area cap for the request.
  final expand = sqrt(1 + 1.4);
  final winW = min(imageWidth, (bbox.w * expand).round());
  final winH = min(imageHeight, (bbox.h * expand).round());
  final winX = _clampInt(
    (centerX - winW / 2).round(),
    0,
    max(0, imageWidth - winW),
  );
  final winY = _clampInt(
    (centerY - winH / 2).round(),
    0,
    max(0, imageHeight - winH),
  );
  final window = CropRect(x: winX, y: winY, w: winW, h: winH);
  final requestSize = requestSizeForWindow(winW, winH, cap);
  final scaled = requestSize.x != winW || requestSize.y != winH;
  return AutocropPlan(
    wholeImageDirect: false,
    window: window,
    requestWidth: requestSize.x,
    requestHeight: requestSize.y,
    scaled: scaled,
    maskBBox: bbox,
  );
}
