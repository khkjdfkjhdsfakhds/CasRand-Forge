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
    final geometry = _contentGeometry(outerW, outerH, step / scaleQuantum);
    if (geometry.area > areaCap) continue;
    if (geometry.contentWidth % latentGrid != 0) continue;
    if (geometry.contentHeight % latentGrid != 0) continue;
    if (geometry.requestWidth > maxRequestSide) continue;
    if (geometry.requestHeight > maxRequestSide) continue;
    return geometry;
  }
  return null;
}

/// Like [_planContent], but also accepts scales below 1.0. A hand-drawn frame
/// may exceed the request budget, in which case its content is scaled down to
/// fit — matching the official manual focus frame, which fits the frame to the
/// request resolution instead of refusing.
_ContentGeometry? _planContentAllowShrink(int outerW, int outerH, int areaCap) {
  final enlarged = _planContent(outerW, outerH, areaCap);
  if (enlarged != null) return enlarged;
  for (var step = scaleQuantum - 1; step >= 5; step--) {
    final geometry = _contentGeometry(outerW, outerH, step / scaleQuantum);
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
  return planFocusForRegion(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    region: bbox,
    maxArea: maxArea,
    contextPx: contextPx,
  );
}

/// Plans the focus frame for one repaint region (the whole mask, or a single
/// tile of a split mask).
FocusInpaintPlan? planFocusForRegion({
  required int imageWidth,
  required int imageHeight,
  required CropRect region,
  required int maxArea,
  int contextPx = defaultContextPx,
}) {
  final context = normalizeContextPx(contextPx);
  // Prefer a frame that also holds the context margin; when the region is so
  // large that the margin no longer fits the budget (a tile of a split mask),
  // fall back to a frame that only has to hold the region itself — the frame
  // is still larger than the region, so it carries context anyway.
  return _planFrameForRegion(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        region: region,
        maxArea: maxArea,
        context: context,
        requireContext: true,
      ) ??
      _planFrameForRegion(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        region: region,
        maxArea: maxArea,
        context: context,
        requireContext: false,
      );
}

FocusInpaintPlan? _planFrameForRegion({
  required int imageWidth,
  required int imageHeight,
  required CropRect region,
  required int maxArea,
  required int context,
  required bool requireContext,
}) {
  final bbox = region;
  final cap = max(minRequestSide * minRequestSide, maxArea);
  final margin = requireContext ? context : 0;

  // The smallest acceptable frame: the region plus its margin, clipped to the
  // image and snapped outward to the latent grid.
  final mustLeft = _floorTo(max(0, bbox.x - margin), latentGrid);
  final mustTop = _floorTo(max(0, bbox.y - margin), latentGrid);
  final mustRight = min(
      imageWidth, _ceilTo(min(imageWidth, bbox.right + margin), latentGrid));
  final mustBottom = min(
      imageHeight, _ceilTo(min(imageHeight, bbox.bottom + margin), latentGrid));
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
  final wholeImage = CropRect(x: 0, y: 0, w: imageWidth, h: imageHeight);
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
  // The effective margin is however much frame surrounds the region, capped
  // at the requested context and kept on the 8-px grid.
  final surround = [
    bbox.x - best.x,
    bbox.y - best.y,
    best.right - bbox.right,
    best.bottom - bbox.bottom,
  ].reduce(min);
  final effectiveContext = _clampInt(
    _floorTo(max(0, surround), latentGrid),
    0,
    context,
  );
  final innerWidth = max(latentGrid, best.w - effectiveContext * 2);
  final innerHeight = max(latentGrid, best.h - effectiveContext * 2);

  return FocusInpaintPlan(
    outer: best,
    inner: CropRect(
      x: best.x + effectiveContext,
      y: best.y + effectiveContext,
      w: innerWidth,
      h: innerHeight,
    ),
    contextPx: effectiveContext,
    scale: scale,
    contentWidth: geometry.contentWidth,
    contentHeight: geometry.contentHeight,
    contentOffsetX: geometry.contentOffsetX,
    contentOffsetY: geometry.contentOffsetY,
    requestWidth: geometry.requestWidth,
    requestHeight: geometry.requestHeight,
  );
}

/// Whether any cell of [cells] inside [frame] is masked.
bool _frameTouchesMask(
  MaskCellGrid cells,
  CropRect frame,
  int imageWidth,
  int imageHeight,
) {
  return maskedCellRatio(cells, frame, imageWidth, imageHeight) > 0;
}

/// Snap a hand-drawn frame onto the latent grid, clipped to the image.
/// Returns null when the frame has no usable area.
CropRect? normalizeManualFrame({
  required CropRect frame,
  required int imageWidth,
  required int imageHeight,
}) {
  if (frame.w <= 0 || frame.h <= 0) return null;
  final left = _clampInt(_floorTo(frame.x, latentGrid), 0, imageWidth);
  final top = _clampInt(_floorTo(frame.y, latentGrid), 0, imageHeight);
  final right = _clampInt(_ceilTo(frame.right, latentGrid), 0, imageWidth);
  final bottom = _clampInt(_ceilTo(frame.bottom, latentGrid), 0, imageHeight);
  if (right - left < latentGrid || bottom - top < latentGrid) return null;
  return CropRect(x: left, y: top, w: right - left, h: bottom - top);
}

/// Plans one focus-inpainting request for a hand-drawn frame.
///
/// The frame replaces Autocrop's automatic search: it is snapped to the
/// latent grid, and its content is scaled to fill the request budget — up
/// like Autocrop, or *down* when the frame itself exceeds the budget (the
/// official manual frame fits oversized frames instead of refusing). Only the
/// mask inside the frame is repainted. Returns null when the frame contains
/// no mask or cannot be planned; the caller falls back to the automatic path.
FocusInpaintPlan? planManualFocusInpaint({
  required int imageWidth,
  required int imageHeight,
  required MaskCellGrid cells,
  required CropRect frame,
  required int maxArea,
}) {
  final snapped = normalizeManualFrame(
    frame: frame,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
  if (snapped == null) return null;
  if (!_frameTouchesMask(cells, snapped, imageWidth, imageHeight)) return null;

  final cap = max(minRequestSide * minRequestSide, maxArea);
  final geometry = _planContentAllowShrink(snapped.w, snapped.h, cap);
  if (geometry == null) return null;

  return FocusInpaintPlan(
    outer: snapped,
    inner: snapped,
    contextPx: 0,
    scale: geometry.scale,
    contentWidth: geometry.contentWidth,
    contentHeight: geometry.contentHeight,
    contentOffsetX: geometry.contentOffsetX,
    contentOffsetY: geometry.contentOffsetY,
    requestWidth: geometry.requestWidth,
    requestHeight: geometry.requestHeight,
  );
}

/// How a mask was split into focus tiles.
enum FocusSplitMode {
  /// One tile covering the whole mask.
  none,

  /// The mask filled its frame, so it was halved along its long axis.
  longAxis,

  /// The mask was too large for one frame and was split into a grid.
  grid,
}

/// A full inpainting batch: one or more focus tiles that together repaint the
/// mask, composited onto the same canvas.
class FocusInpaintBatch {
  final List<FocusInpaintPlan> tiles;
  final FocusSplitMode splitMode;

  /// Tiles must run one after another when their frames overlap, because a
  /// later tile has to see the previous tile's result.
  final bool serial;

  const FocusInpaintBatch({
    required this.tiles,
    required this.splitMode,
    required this.serial,
  });

  int get tileCount => tiles.length;
  bool get isSplit => tiles.length > 1;
}

/// Snap a split boundary onto the 8-px grid, staying within (lower, upper).
int _snapBoundary(int value, int lower, int upper) {
  if (upper < lower) return lower;
  for (final candidate in [
    (value / latentGrid).round() * latentGrid,
    (value ~/ latentGrid) * latentGrid,
    ((value + latentGrid - 1) ~/ latentGrid) * latentGrid,
  ]) {
    if (candidate >= lower && candidate <= upper) return candidate;
  }
  return _clampInt(value, lower, upper);
}

/// Split boundaries for [count] even slices of [start, start + size).
List<int> _splitBoundaries(int start, int size, int count) {
  final end = start + size;
  if (count <= 1 || size <= 1) return [start, end];
  final result = <int>[start];
  for (var index = 1; index < count; index++) {
    final even = start + (size * index) ~/ count;
    final lower = result.last + 1;
    final upper = end - (count - index);
    result.add(_snapBoundary(even, lower, upper));
  }
  result.add(end);
  return result;
}

/// Halve [rect] along its longer axis.
List<CropRect> splitAlongLongAxis(CropRect rect) {
  if (rect.w <= 0 || rect.h <= 0) return [rect];
  if (rect.w >= rect.h) {
    if (rect.w < 16) return [rect];
    final cut = _snapBoundary(rect.x + rect.w ~/ 2, rect.x + 1, rect.right - 1);
    if (cut <= rect.x || cut >= rect.right) return [rect];
    return [
      CropRect(x: rect.x, y: rect.y, w: cut - rect.x, h: rect.h),
      CropRect(x: cut, y: rect.y, w: rect.right - cut, h: rect.h),
    ];
  }
  if (rect.h < 16) return [rect];
  final cut = _snapBoundary(rect.y + rect.h ~/ 2, rect.y + 1, rect.bottom - 1);
  if (cut <= rect.y || cut >= rect.bottom) return [rect];
  return [
    CropRect(x: rect.x, y: rect.y, w: rect.w, h: cut - rect.y),
    CropRect(x: rect.x, y: cut, w: rect.w, h: rect.bottom - cut),
  ];
}

/// Split [rect] into a grid of tiles no larger than [tileWidth] x [tileHeight].
List<CropRect> splitIntoGrid(CropRect rect, int tileWidth, int tileHeight) {
  final cols = max(1, (rect.w / max(1, tileWidth)).ceil());
  final rows = max(1, (rect.h / max(1, tileHeight)).ceil());
  final xs = _splitBoundaries(rect.x, rect.w, cols);
  final ys = _splitBoundaries(rect.y, rect.h, rows);
  final result = <CropRect>[];
  for (var row = 0; row < rows; row++) {
    final top = ys[row];
    final bottom = ys[row + 1];
    for (var col = 0; col < cols; col++) {
      final left = xs[col];
      final right = xs[col + 1];
      if (right > left && bottom > top) {
        result.add(
          CropRect(x: left, y: top, w: right - left, h: bottom - top),
        );
      }
    }
  }
  return result;
}

/// Tile size that splits [rect] into the fewest pieces within the area cap,
/// preferring a tile aspect close to the region's own.
Point<int> bestTileSizeFor(CropRect rect, int maxArea) {
  final regionAspect = log(max(1, rect.w) / max(1, rect.h));
  Point<int>? best;
  var bestCount = 1 << 30;
  var bestAspectDiff = double.infinity;
  for (final size in candidateSizesForArea(maxArea)) {
    final w = min(size.x, maxRequestSide);
    final h = min(size.y, maxRequestSide);
    final count = (rect.w / max(1, w)).ceil() * (rect.h / max(1, h)).ceil();
    final aspectDiff = (log(w / h) - regionAspect).abs();
    if (count < bestCount ||
        (count == bestCount && aspectDiff < bestAspectDiff)) {
      best = Point(w, h);
      bestCount = count;
      bestAspectDiff = aspectDiff;
    }
  }
  return best ?? const Point(1024, 1024);
}

/// Fraction of the frame's latent cells that the mask covers.
double maskedCellRatio(
  MaskCellGrid cells,
  CropRect frame,
  int imageWidth,
  int imageHeight,
) {
  final left = max(0, frame.x) ~/ maskCellSize;
  final top = max(0, frame.y) ~/ maskCellSize;
  final right = (min(imageWidth, frame.right) / maskCellSize).ceil();
  final bottom = (min(imageHeight, frame.bottom) / maskCellSize).ceil();
  if (right <= left || bottom <= top) return 0;
  var masked = 0;
  var total = 0;
  for (var cy = top; cy < bottom; cy++) {
    for (var cx = left; cx < right; cx++) {
      total++;
      if (cells.cellAt(cx, cy)) masked++;
    }
  }
  return total == 0 ? 0 : masked / total;
}

bool _rectsOverlap(CropRect a, CropRect b) {
  return a.x < b.right && b.x < a.right && a.y < b.bottom && b.y < a.bottom;
}

bool _anyFramesOverlap(List<FocusInpaintPlan> tiles) {
  for (var i = 0; i < tiles.length; i++) {
    for (var j = i + 1; j < tiles.length; j++) {
      if (_rectsOverlap(tiles[i].outer, tiles[j].outer)) return true;
    }
  }
  return false;
}

/// Ratio above which a frame counts as "mostly mask" and gets split so each
/// half is repainted at a higher effective resolution.
const double longAxisSplitThreshold = 0.75;

/// Plans the whole inpainting batch, splitting the mask into several focus
/// tiles when one frame cannot cover it (grid) or would be almost entirely
/// masked (long axis).
///
/// Returns null when the mask is empty or no tile can be planned, in which
/// case the caller falls back to a whole-image request.
FocusInpaintBatch? planFocusInpaintBatch({
  required int imageWidth,
  required int imageHeight,
  required MaskCellGrid cells,
  required int maxArea,
  int contextPx = defaultContextPx,
}) {
  final bbox = maskBBoxFromCells(cells, imageWidth, imageHeight);
  if (bbox == null) return null;
  final cap = max(minRequestSide * minRequestSide, maxArea);

  final single = planFocusForRegion(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    region: bbox,
    maxArea: cap,
    contextPx: contextPx,
  );

  List<CropRect> regions;
  var splitMode = FocusSplitMode.none;
  if (single != null) {
    // One frame covers the mask. Split it only when the frame is almost all
    // mask, where two halves each get a better effective resolution.
    final ratio = maskedCellRatio(cells, single.outer, imageWidth, imageHeight);
    if (ratio > longAxisSplitThreshold) {
      final halves = splitAlongLongAxis(bbox);
      if (halves.length > 1) {
        regions = halves;
        splitMode = FocusSplitMode.longAxis;
      } else {
        regions = [bbox];
      }
    } else {
      regions = [bbox];
    }
  } else {
    // The mask does not fit one frame; tile it.
    final tileSize = bestTileSizeFor(bbox, cap);
    regions = splitIntoGrid(bbox, tileSize.x, tileSize.y);
    splitMode = regions.length > 1 ? FocusSplitMode.grid : FocusSplitMode.none;
  }

  // Plan each region, dropping duplicate frames so overlapping regions that
  // resolve to the same frame are only requested once.
  final tiles = <FocusInpaintPlan>[];
  final seenFrames = <String>{};
  for (final region in regions) {
    final plan = planFocusForRegion(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      region: region,
      maxArea: cap,
      contextPx: contextPx,
    );
    if (plan == null) continue;
    final key = '${plan.outer.x},${plan.outer.y},'
        '${plan.outer.w},${plan.outer.h}';
    if (!seenFrames.add(key)) continue;
    tiles.add(plan);
  }
  if (tiles.isEmpty) return null;
  if (tiles.length == 1) splitMode = FocusSplitMode.none;

  return FocusInpaintBatch(
    tiles: tiles,
    splitMode: splitMode,
    // Overlapping frames must be sequential so each tile sees the previous
    // result; a long-axis split always produces overlapping frames.
    serial: tiles.length <= 1 ||
        splitMode == FocusSplitMode.longAxis ||
        _anyFramesOverlap(tiles),
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
