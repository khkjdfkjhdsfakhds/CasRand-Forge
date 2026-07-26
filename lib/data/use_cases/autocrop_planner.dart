import 'dart:math';
import 'dart:typed_data';

/// Planner for NovelAI's focus inpainting, driven automatically from the mask
/// (the "Autocrop" switch) instead of a hand-drawn frame.
///
/// Focus inpainting does not simply crop a request-sized tile. It takes an
/// `outer` frame around the repaint area, scales that frame so the content
/// fills the request budget as fully as possible, centers it on a 64-aligned
/// request canvas, and scales the response back down when compositing. The
/// scale is never below 1.0: a frame smaller than the budget is enlarged so
/// the model gets the full canvas to work with, and a frame larger than the
/// budget is rejected rather than shrunk.
///
/// Autocrop's own job is to choose that `outer` frame: centered on the mask,
/// pulled as large as the budget and the source image allow, since a larger
/// frame (more context, scale near 1.0) consistently beats a tight frame at a
/// high magnification.
const int maskCellSize = 8;
const int latentGrid = 8;
const int sizeStep = 64;
const int minRequestSide = 64;
const int maxRequestSide = 1728;

/// Scale is quantized to 1/100 steps, matching the reference implementation.
const int scaleQuantum = 100;

/// Context margin added around the mask bounding box, in source pixels.
/// Focus inpainting constrains this to the 8-px grid within [32, 96].
const int minContextPx = 32;
const int maxContextPx = 96;
const int defaultContextPx = 64;

/// Area caps matching NovelAI's size tiers.
const int areaCapNormal = 1024 * 1024;
const int areaCapLarge = 1472 * 1472;
const int areaCapWallpaper = 1728 * 1728;

/// Candidate aspect ratios (NovelAI presets) used to shape the outer frame.
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

/// A planned focus-inpainting request.
class FocusInpaintPlan {
  /// Frame taken from the source image. May extend past the image bounds;
  /// the outside part is padded black and never composited back.
  final CropRect outer;

  /// [outer] shrunk by [contextPx] — the area the mask is allowed to occupy.
  final CropRect inner;

  final int contextPx;

  /// Magnification applied to [outer]. Always >= 1.0.
  final double scale;

  /// Size of the scaled outer content inside the request canvas.
  final int contentWidth;
  final int contentHeight;

  /// Where the content sits on the request canvas (centered, 8-px aligned).
  final int contentOffsetX;
  final int contentOffsetY;

  /// The request canvas, 64-aligned and within the area cap.
  final int requestWidth;
  final int requestHeight;

  const FocusInpaintPlan({
    required this.outer,
    required this.inner,
    required this.contextPx,
    required this.scale,
    required this.contentWidth,
    required this.contentHeight,
    required this.contentOffsetX,
    required this.contentOffsetY,
    required this.requestWidth,
    required this.requestHeight,
  });

  /// True when the request canvas is exactly the outer frame at 1:1, so the
  /// response can be pasted back without resampling.
  bool get isNativeScale => scale == 1.0;

  /// True when the whole source image is the outer frame at 1:1.
  bool coversWholeImage(int imageWidth, int imageHeight) {
    return outer.x == 0 &&
        outer.y == 0 &&
        outer.w == imageWidth &&
        outer.h == imageHeight;
  }

  String describe() {
    final scaleText = scale == 1.0 ? '1.00x' : '${scale.toStringAsFixed(2)}x';
    return 'outer ${outer.w}x${outer.h}@(${outer.x},${outer.y}) '
        'scale $scaleText -> content ${contentWidth}x$contentHeight '
        'on ${requestWidth}x$requestHeight canvas';
  }
}

int _clampInt(int value, int lower, int upper) => max(lower, min(upper, value));

int _ceilTo(int value, int step) => ((max(0, value) + step - 1) ~/ step) * step;

int _floorTo(int value, int step) => (max(0, value) ~/ step) * step;

/// Area cap for a given request size, mirroring NovelAI size tiers.
int areaCapForSize(int width, int height) {
  final area = width * height;
  if (area <= areaCapNormal) return areaCapNormal;
  if (area <= areaCapLarge) return areaCapLarge;
  return areaCapWallpaper;
}

/// Snap a requested context margin onto the 8-px grid within [32, 96].
int normalizeContextPx(int value) {
  final snapped = (value / latentGrid).round() * latentGrid;
  return _clampInt(snapped, minContextPx, maxContextPx);
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

/// Candidate 64-aligned outer sizes for an area cap, one per aspect ratio.
List<Point<int>> candidateSizesForArea(int maxArea) {
  final result = <Point<int>>[];
  final seen = <String>{};
  for (final aspect in aspectCandidates) {
    final ratio = aspect.x / aspect.y;
    var w = _clampInt(_floorTo(sqrt(maxArea * ratio).floor(), sizeStep),
        minRequestSide, maxRequestSide);
    var h = _clampInt(_floorTo(sqrt(maxArea / ratio).floor(), sizeStep),
        minRequestSide, maxRequestSide);
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

/// Geometry of the scaled content on its request canvas.
class _ContentGeometry {
  final double scale;
  final int contentWidth;
  final int contentHeight;
  final int requestWidth;
  final int requestHeight;
  final int contentOffsetX;
  final int contentOffsetY;

  const _ContentGeometry({
    required this.scale,
    required this.contentWidth,
    required this.contentHeight,
    required this.requestWidth,
    required this.requestHeight,
    required this.contentOffsetX,
    required this.contentOffsetY,
  });

  int get area => requestWidth * requestHeight;
}

int _centerOffset(int outerSize, int innerSize) {
  final slack = outerSize - innerSize;
  if (slack <= 0) return 0;
  return _clampInt((slack / 2 / latentGrid).round() * latentGrid, 0, slack);
}

_ContentGeometry _contentGeometry(int outerW, int outerH, double scale) {
  final contentWidth = max(1, (outerW * scale).round());
  final contentHeight = max(1, (outerH * scale).round());
  final requestWidth = _ceilTo(contentWidth, sizeStep);
  final requestHeight = _ceilTo(contentHeight, sizeStep);
  return _ContentGeometry(
    scale: scale,
    contentWidth: contentWidth,
    contentHeight: contentHeight,
    requestWidth: requestWidth,
    requestHeight: requestHeight,
    contentOffsetX: _centerOffset(requestWidth, contentWidth),
    contentOffsetY: _centerOffset(requestHeight, contentHeight),
  );
}

/// Picks the largest scale (>= 1.0) whose request canvas fits [areaCap] and
/// whose content stays aligned to the latent grid. Returns null when even 1:1
/// exceeds the cap — focus inpainting never shrinks the frame.
_ContentGeometry? _planContent(int outerW, int outerH, int areaCap) {
  var steps =
      ((sqrt(areaCap / (outerW * outerH)) + 1e-9) * scaleQuantum).floor();
  steps = max(scaleQuantum, steps);
  for (var step = steps; step >= scaleQuantum; step--) {
    final geometry =
        _contentGeometry(outerW, outerH, step / scaleQuantum);
    if (geometry.area > areaCap) continue;
    if (geometry.contentWidth % latentGrid != 0) continue;
    if (geometry.contentHeight % latentGrid != 0) continue;
    if (geometry.requestWidth > maxRequestSide) continue;
    if (geometry.requestHeight > maxRequestSide) continue;
    return geometry;
  }
  return null;
}

/// Places a frame of [size] centered on [center] while keeping [must] inside
/// and the frame within the source bounds. Returns null when impossible.
int? _placeAxis({
  required int size,
  required double center,
  required int mustStart,
  required int mustEnd,
  required int sourceSize,
}) {
  if (size < mustEnd - mustStart) return null;
  if (size > sourceSize) return null;
  final lower = max(0, mustEnd - size);
  final upper = min(sourceSize - size, mustStart);
  if (lower > upper) return null;
  final raw = _clampInt((center - size / 2).round(), lower, upper);
  // Keep the frame on the latent grid so mask cells map cleanly.
  final snapped = _clampInt(_floorTo(raw, latentGrid), lower, upper);
  return snapped;
}

/// Plans one focus-inpainting request for the mask.
///
/// Returns null when the mask is empty, or when the repaint area plus its
/// context margin cannot fit the area cap at 1:1 — focus inpainting refuses to
/// shrink, so the caller must fall back to a plain whole-image request.
FocusInpaintPlan? planFocusInpaint({
  required int imageWidth,
  required int imageHeight,
  required MaskCellGrid cells,
  required int maxArea,
  int contextPx = defaultContextPx,
}) {
  final bbox = maskBBoxFromCells(cells, imageWidth, imageHeight);
  if (bbox == null) return null;
  final cap = max(minRequestSide * minRequestSide, maxArea);
  final context = normalizeContextPx(contextPx);

  // The smallest acceptable frame: the mask plus its context margin, clipped
  // to the image and snapped outward to the latent grid.
  final mustLeft = _floorTo(max(0, bbox.x - context), latentGrid);
  final mustTop = _floorTo(max(0, bbox.y - context), latentGrid);
  final mustRight =
      min(imageWidth, _ceilTo(min(imageWidth, bbox.right + context), latentGrid));
  final mustBottom = min(
      imageHeight, _ceilTo(min(imageHeight, bbox.bottom + context), latentGrid));
  final must = CropRect(
    x: mustLeft,
    y: mustTop,
    w: mustRight - mustLeft,
    h: mustBottom - mustTop,
  );
  final centerX = bbox.x + bbox.w / 2;
  final centerY = bbox.y + bbox.h / 2;

  // Autocrop pulls the frame as large as the budget and the image allow.
  // Larger frame, more context, scale closer to 1.0 — which beats a tight
  // frame blown up at high magnification.
  CropRect? best;
  var bestArea = -1;

  // The whole image is the largest frame there is; prefer it whenever it fits
  // the budget, so a compliant source is sent untouched at 1:1.
  final wholeImage =
      CropRect(x: 0, y: 0, w: imageWidth, h: imageHeight);
  if (wholeImage.contains(must) &&
      _planContent(imageWidth, imageHeight, cap) != null) {
    best = wholeImage;
    bestArea = wholeImage.area;
  }

  for (final size in candidateSizesForArea(cap)) {
    final width = min(size.x, imageWidth);
    final height = min(size.y, imageHeight);
    final x = _placeAxis(
      size: width,
      center: centerX,
      mustStart: must.x,
      mustEnd: must.right,
      sourceSize: imageWidth,
    );
    final y = _placeAxis(
      size: height,
      center: centerY,
      mustStart: must.y,
      mustEnd: must.bottom,
      sourceSize: imageHeight,
    );
    if (x == null || y == null) continue;
    final frame = CropRect(x: x, y: y, w: width, h: height);
    if (!frame.contains(must)) continue;
    if (_planContent(frame.w, frame.h, cap) == null) continue;
    if (frame.area > bestArea) {
      best = frame;
      bestArea = frame.area;
    }
  }

  // No preset frame fits (small image, or mask spanning most of it): fall back
  // to the tightest frame that still holds the mask and its margin.
  best ??= _planContent(must.w, must.h, cap) == null ? null : must;
  if (best == null) return null;

  final geometry = _planContent(best.w, best.h, cap);
  if (geometry == null) return null;

  final scale = geometry.scale;
  final innerLeft = best.x + context;
  final innerTop = best.y + context;
  final innerWidth = max(latentGrid, best.w - context * 2);
  final innerHeight = max(latentGrid, best.h - context * 2);

  return FocusInpaintPlan(
    outer: best,
    inner: CropRect(
      x: innerLeft,
      y: innerTop,
      w: innerWidth,
      h: innerHeight,
    ),
    contextPx: context,
    scale: scale,
    contentWidth: geometry.contentWidth,
    contentHeight: geometry.contentHeight,
    contentOffsetX: geometry.contentOffsetX,
    contentOffsetY: geometry.contentOffsetY,
    requestWidth: geometry.requestWidth,
    requestHeight: geometry.requestHeight,
  );
}

/// Whether a plain whole-image inpaint request is possible without resampling.
bool wholeImageFitsDirect(int width, int height, int maxArea) {
  return width >= minRequestSide &&
      height >= minRequestSide &&
      width <= maxRequestSide &&
      height <= maxRequestSide &&
      width % sizeStep == 0 &&
      height % sizeStep == 0 &&
      width * height <= maxArea;
}

/// Scale (w, h) down so its area fits the cap; snap to 64 within
/// [minRequestSide, maxRequestSide]. Used only by the non-focus fallback.
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
