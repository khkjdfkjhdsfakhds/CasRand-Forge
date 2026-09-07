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
/// the model gets the full canvas to work with. Automatic regions that cannot
/// fit are split; oversized hand-drawn frames are proportionally capped before
/// planning.
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

/// Official Focused Inpainting selection/request ceiling. Larger repaint
/// regions must be split into several focus tiles instead of being silently
/// shrunk into one request.
const int focusFrameMaxArea = areaCapNormal;

/// Prevent imported masks with many isolated specks from turning one click
/// into an unbounded number of paid Focus requests.
const int maxFocusTiles = 16;

/// Automatic Focus Inpainting is only useful beyond NovelAI's normal free
/// image area. The preference may remain enabled for smaller images, but the
/// request must stay on the whole-image inpaint path until this returns true.
bool autocropAppliesToImage(int width, int height) {
  return width * height > areaCapNormal;
}

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

/// Actual non-repainted context available on each side of a Focus frame.
/// A source-image edge can reduce one side without discarding the others.
class FocusContextInsets {
  final int left;
  final int top;
  final int right;
  final int bottom;

  const FocusContextInsets({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  const FocusContextInsets.uniform(int value)
      : left = value,
        top = value,
        right = value,
        bottom = value;

  int get minimum => min(min(left, right), min(top, bottom));
}

class FocusInpaintTileLimitException implements Exception {
  final int tileCount;
  final int maxTiles;

  const FocusInpaintTileLimitException(this.tileCount, this.maxTiles);

  @override
  String toString() => 'AutoCrop needs $tileCount Focus requests, but the '
      'safe maximum is $maxTiles. Reduce or merge the painted regions.';
}

/// A planned focus-inpainting request.
class FocusInpaintPlan {
  /// Frame taken from the source image. May extend past the image bounds;
  /// the outside part is padded black and never composited back.
  final CropRect outer;

  /// [outer] inset by [contextInsets] — the area the mask may occupy.
  final CropRect inner;

  final FocusContextInsets contextInsets;

  /// Exact 8-px mask cells owned by this request. Null is reserved for public
  /// single-region geometry helpers and maskless manual Focus.
  final MaskCellGrid? repaintCells;

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
    required this.contextInsets,
    this.repaintCells,
    required this.scale,
    required this.contentWidth,
    required this.contentHeight,
    required this.contentOffsetX,
    required this.contentOffsetY,
    required this.requestWidth,
    required this.requestHeight,
  });

  /// Backward-compatible minimum effective context. New code should inspect
  /// [contextInsets] because edge frames can be asymmetric.
  int get contextPx => contextInsets.minimum;

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
  final cap = min(
    focusFrameMaxArea,
    max(minRequestSide * minRequestSide, maxArea),
  );
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

  // The whole image is the largest frame there is; prefer it whenever it fits
  // the budget, so a compliant source is sent untouched at 1:1.
  final wholeImage = CropRect(x: 0, y: 0, w: imageWidth, h: imageHeight);
  if (wholeImage.contains(must) &&
      _planContent(imageWidth, imageHeight, cap) != null) {
    best = wholeImage;
  }

  final candidates = <CropRect>[];
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
    candidates.add(frame);
  }

  // When the source itself does not fit, prefer a preset whose aspect follows
  // the mask plus its requested context. Candidates within 95% of the largest
  // usable area are effectively equal in context/resolution, so aspect match
  // is more useful than blindly picking the square with a few extra pixels.
  if (best == null && candidates.isNotEmpty) {
    final largestArea = candidates.map((frame) => frame.area).reduce(max);
    final nearLargest =
        candidates.where((frame) => frame.area >= largestArea * 0.95).toList();
    final targetAspect = log(max(1, must.w) / max(1, must.h));
    nearLargest.sort((a, b) {
      final aDiff = (log(a.w / a.h) - targetAspect).abs();
      final bDiff = (log(b.w / b.h) - targetAspect).abs();
      final aspectOrder = aDiff.compareTo(bDiff);
      if (aspectOrder != 0) return aspectOrder;
      return b.area.compareTo(a.area);
    });
    best = nearLargest.first;
  }

  // No preset frame fits (small image, or mask spanning most of it): fall back
  // to the tightest frame that still holds the mask and its margin.
  best ??= _planContent(must.w, must.h, cap) == null ? null : must;
  if (best == null) return null;

  final geometry = _planContent(best.w, best.h, cap);
  if (geometry == null) return null;

  final scale = geometry.scale;
  // Keep every available side independently. A mask touching the source edge
  // has no context on that side, but must retain context on the other sides.
  final contextInsets = FocusContextInsets(
    left: _clampInt(
      _floorTo(max(0, bbox.x - best.x), latentGrid),
      0,
      context,
    ),
    top: _clampInt(
      _floorTo(max(0, bbox.y - best.y), latentGrid),
      0,
      context,
    ),
    right: _clampInt(
      _floorTo(max(0, best.right - bbox.right), latentGrid),
      0,
      context,
    ),
    bottom: _clampInt(
      _floorTo(max(0, best.bottom - bbox.bottom), latentGrid),
      0,
      context,
    ),
  );
  final innerWidth = max(
    latentGrid,
    best.w - contextInsets.left - contextInsets.right,
  );
  final innerHeight = max(
    latentGrid,
    best.h - contextInsets.top - contextInsets.bottom,
  );

  return FocusInpaintPlan(
    outer: best,
    inner: CropRect(
      x: best.x + contextInsets.left,
      y: best.y + contextInsets.top,
      w: innerWidth,
      h: innerHeight,
    ),
    contextInsets: contextInsets,
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

/// Snap a hand-drawn frame onto the latent grid, clipped to the image. Frames
/// may stay below [maxArea], but an oversized frame is reduced proportionally
/// until both its pixels and aligned request canvas fit the Focus budget.
/// Returns null when the frame has no usable area.
CropRect? normalizeManualFrame({
  required CropRect frame,
  required int imageWidth,
  required int imageHeight,
  int maxArea = focusFrameMaxArea,
}) {
  if (frame.w <= 0 || frame.h <= 0) return null;
  final left = _clampInt(_floorTo(frame.x, latentGrid), 0, imageWidth);
  final top = _clampInt(_floorTo(frame.y, latentGrid), 0, imageHeight);
  final right = _clampInt(_ceilTo(frame.right, latentGrid), 0, imageWidth);
  final bottom = _clampInt(_ceilTo(frame.bottom, latentGrid), 0, imageHeight);
  final snappedWidth = right - left;
  final snappedHeight = bottom - top;
  if (snappedWidth < latentGrid || snappedHeight < latentGrid) return null;

  final cap = max(minRequestSide * minRequestSide, maxArea);
  final initialScale = min(
    1.0,
    min(
      sqrt(cap / (snappedWidth * snappedHeight)),
      min(
        maxRequestSide / snappedWidth,
        maxRequestSide / snappedHeight,
      ),
    ),
  );
  final centerX = left + snappedWidth / 2;
  final centerY = top + snappedHeight / 2;

  // Request dimensions are 64-aligned, so a frame just below the pixel cap
  // can still need a small further reduction. Search downward in 1% steps;
  // the selected aspect remains stable while the request becomes valid.
  for (var step = 100; step >= 1; step--) {
    final scale = initialScale * step / 100;
    final width = max(
      latentGrid,
      _floorTo((snappedWidth * scale).floor(), latentGrid),
    );
    final height = max(
      latentGrid,
      _floorTo((snappedHeight * scale).floor(), latentGrid),
    );
    if (width > imageWidth || height > imageHeight || width * height > cap) {
      continue;
    }
    if (_planContent(width, height, cap) == null) continue;

    final maxX = _floorTo(imageWidth - width, latentGrid);
    final maxY = _floorTo(imageHeight - height, latentGrid);
    final x = _clampInt(
      _floorTo((centerX - width / 2).round(), latentGrid),
      0,
      maxX,
    );
    final y = _clampInt(
      _floorTo((centerY - height / 2).round(), latentGrid),
      0,
      maxY,
    );
    return CropRect(x: x, y: y, w: width, h: height);
  }
  return null;
}

/// Plans one focus-inpainting request for a hand-drawn frame.
///
/// The frame replaces Autocrop's automatic search: it is snapped to the
/// latent grid, and its content is scaled up to fill the request budget. A
/// frame above the official 1 MP Focused Inpainting limit is proportionally
/// capped. Only the mask inside the frame is repainted. When [cells] is null,
/// the whole inner region is repainted, matching the website's maskless Focus
/// mode.
FocusInpaintPlan? planManualFocusInpaint({
  required int imageWidth,
  required int imageHeight,
  required MaskCellGrid? cells,
  required CropRect frame,
  required int maxArea,
  int contextPx = defaultContextPx,
}) {
  final cap = min(
    focusFrameMaxArea,
    max(minRequestSide * minRequestSide, maxArea),
  );
  final snapped = normalizeManualFrame(
    frame: frame,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    maxArea: cap,
  );
  if (snapped == null) return null;
  final requestedContext = normalizeContextPx(contextPx);
  final effectiveContext = min(
    requestedContext,
    min(
      max(0, (snapped.w - latentGrid) ~/ 2),
      max(0, (snapped.h - latentGrid) ~/ 2),
    ),
  );
  final inner = CropRect(
    x: snapped.x + effectiveContext,
    y: snapped.y + effectiveContext,
    w: snapped.w - effectiveContext * 2,
    h: snapped.h - effectiveContext * 2,
  );
  if (cells != null &&
      !_frameTouchesMask(cells, inner, imageWidth, imageHeight)) {
    return null;
  }

  final geometry = _planContent(snapped.w, snapped.h, cap);
  if (geometry == null) return null;

  return FocusInpaintPlan(
    outer: snapped,
    inner: inner,
    contextInsets: FocusContextInsets.uniform(effectiveContext),
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

  /// Disconnected mask islands were planned independently.
  islands,

  /// Disconnected islands included at least one internally split region.
  mixed,
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

class _MaskRegion {
  final List<int> indices;
  final CropRect bbox;

  const _MaskRegion({required this.indices, required this.bbox});
}

class _OwnedFocusPlan {
  final FocusInpaintPlan geometry;
  final _MaskRegion region;

  const _OwnedFocusPlan({required this.geometry, required this.region});
}

class _RegionPlanResult {
  final List<_OwnedFocusPlan> plans;
  final FocusSplitMode splitMode;

  const _RegionPlanResult({required this.plans, required this.splitMode});
}

_MaskRegion _maskRegionFromIndices(
  List<int> indices,
  MaskCellGrid cells,
  int imageWidth,
  int imageHeight,
) {
  var minCx = cells.width;
  var minCy = cells.height;
  var maxCx = -1;
  var maxCy = -1;
  for (final index in indices) {
    final cx = index % cells.width;
    final cy = index ~/ cells.width;
    minCx = min(minCx, cx);
    minCy = min(minCy, cy);
    maxCx = max(maxCx, cx);
    maxCy = max(maxCy, cy);
  }
  return _MaskRegion(
    indices: indices,
    bbox: CropRect(
      x: minCx * maskCellSize,
      y: minCy * maskCellSize,
      w: min(imageWidth, (maxCx + 1) * maskCellSize) - minCx * maskCellSize,
      h: min(imageHeight, (maxCy + 1) * maskCellSize) - minCy * maskCellSize,
    ),
  );
}

List<_MaskRegion> _connectedMaskRegions(
  MaskCellGrid cells,
  int imageWidth,
  int imageHeight,
) {
  final visited = Uint8List(cells.data.length);
  final regions = <_MaskRegion>[];
  for (var start = 0; start < cells.data.length; start++) {
    if (cells.data[start] == 0 || visited[start] != 0) continue;
    final queue = <int>[start];
    final indices = <int>[];
    visited[start] = 1;
    for (var head = 0; head < queue.length; head++) {
      final index = queue[head];
      indices.add(index);
      final cx = index % cells.width;
      final cy = index ~/ cells.width;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = cx + dx;
          final ny = cy + dy;
          if (nx < 0 || ny < 0 || nx >= cells.width || ny >= cells.height) {
            continue;
          }
          final neighbor = ny * cells.width + nx;
          if (cells.data[neighbor] == 0 || visited[neighbor] != 0) continue;
          visited[neighbor] = 1;
          queue.add(neighbor);
        }
      }
    }
    regions.add(
      _maskRegionFromIndices(
        indices,
        cells,
        imageWidth,
        imageHeight,
      ),
    );
  }
  return regions;
}

List<_MaskRegion> _partitionMaskRegion(
  _MaskRegion source,
  List<CropRect> partitions,
  MaskCellGrid cells,
  int imageWidth,
  int imageHeight,
) {
  final buckets = List.generate(partitions.length, (_) => <int>[]);
  for (final index in source.indices) {
    final x = (index % cells.width) * maskCellSize;
    final y = (index ~/ cells.width) * maskCellSize;
    var owner = partitions.indexWhere(
      (rect) => x >= rect.x && x < rect.right && y >= rect.y && y < rect.bottom,
    );
    if (owner < 0) owner = partitions.length - 1;
    buckets[owner].add(index);
  }
  return buckets
      .where((bucket) => bucket.isNotEmpty)
      .map(
        (bucket) => _maskRegionFromIndices(
          bucket,
          cells,
          imageWidth,
          imageHeight,
        ),
      )
      .toList(growable: false);
}

double _maskedRatioForRegion(
  _MaskRegion region,
  CropRect frame,
  MaskCellGrid cells,
  int imageWidth,
  int imageHeight,
) {
  final left = max(0, frame.x) ~/ maskCellSize;
  final top = max(0, frame.y) ~/ maskCellSize;
  final right = (min(imageWidth, frame.right) / maskCellSize).ceil();
  final bottom = (min(imageHeight, frame.bottom) / maskCellSize).ceil();
  final total = max(0, right - left) * max(0, bottom - top);
  if (total == 0) return 0;
  var masked = 0;
  for (final index in region.indices) {
    final cx = index % cells.width;
    final cy = index ~/ cells.width;
    if (cx >= left && cx < right && cy >= top && cy < bottom) masked++;
  }
  return masked / total;
}

_RegionPlanResult? _planOwnedMaskRegion({
  required _MaskRegion region,
  required MaskCellGrid cells,
  required int imageWidth,
  required int imageHeight,
  required int maxArea,
  required int contextPx,
}) {
  final single = planFocusForRegion(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    region: region.bbox,
    maxArea: maxArea,
    contextPx: contextPx,
  );
  List<_MaskRegion> pieces;
  var splitMode = FocusSplitMode.none;
  if (single != null) {
    final ratio = _maskedRatioForRegion(
      region,
      single.outer,
      cells,
      imageWidth,
      imageHeight,
    );
    if (ratio > longAxisSplitThreshold) {
      pieces = _partitionMaskRegion(
        region,
        splitAlongLongAxis(region.bbox),
        cells,
        imageWidth,
        imageHeight,
      );
      if (pieces.length > 1) splitMode = FocusSplitMode.longAxis;
    } else {
      pieces = [region];
    }
  } else {
    final tileSize = bestTileSizeFor(region.bbox, maxArea);
    pieces = _partitionMaskRegion(
      region,
      splitIntoGrid(region.bbox, tileSize.x, tileSize.y),
      cells,
      imageWidth,
      imageHeight,
    );
    if (pieces.length > 1) splitMode = FocusSplitMode.grid;
  }

  final plans = <_OwnedFocusPlan>[];
  for (final piece in pieces) {
    final geometry = planFocusForRegion(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      region: piece.bbox,
      maxArea: maxArea,
      contextPx: contextPx,
    );
    if (geometry == null || !geometry.inner.contains(piece.bbox)) return null;
    plans.add(_OwnedFocusPlan(geometry: geometry, region: piece));
  }
  return _RegionPlanResult(plans: plans, splitMode: splitMode);
}

List<_OwnedFocusPlan> _mergeEquivalentFocusFrames({
  required List<_OwnedFocusPlan> plans,
  required MaskCellGrid cells,
  required int imageWidth,
  required int imageHeight,
  required int maxArea,
  required int contextPx,
}) {
  final groups = <CropRect, List<_OwnedFocusPlan>>{};
  for (final plan in plans) {
    groups.putIfAbsent(plan.geometry.outer, () => []).add(plan);
  }
  final merged = <_OwnedFocusPlan>[];
  for (final entry in groups.entries) {
    if (entry.value.length == 1) {
      merged.add(entry.value.single);
      continue;
    }
    final indices = entry.value
        .expand((plan) => plan.region.indices)
        .toList(growable: false)
      ..sort();
    final region = _maskRegionFromIndices(
      indices,
      cells,
      imageWidth,
      imageHeight,
    );
    final geometry = planFocusForRegion(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      region: region.bbox,
      maxArea: maxArea,
      contextPx: contextPx,
    );
    if (geometry != null &&
        geometry.outer == entry.key &&
        geometry.inner.contains(region.bbox)) {
      merged.add(_OwnedFocusPlan(geometry: geometry, region: region));
    } else {
      merged.addAll(entry.value);
    }
  }
  return merged;
}

MaskCellGrid _ownedCellGrid(_MaskRegion region, MaskCellGrid source) {
  final data = Uint8List(source.data.length);
  for (final index in region.indices) {
    data[index] = 1;
  }
  return MaskCellGrid(data: data, width: source.width, height: source.height);
}

FocusInpaintPlan _withOwnedCells(
  FocusInpaintPlan geometry,
  MaskCellGrid repaintCells,
) {
  return FocusInpaintPlan(
    outer: geometry.outer,
    inner: geometry.inner,
    contextInsets: geometry.contextInsets,
    repaintCells: repaintCells,
    scale: geometry.scale,
    contentWidth: geometry.contentWidth,
    contentHeight: geometry.contentHeight,
    contentOffsetX: geometry.contentOffsetX,
    contentOffsetY: geometry.contentOffsetY,
    requestWidth: geometry.requestWidth,
    requestHeight: geometry.requestHeight,
  );
}

void _validateOwnedCoverage(
  MaskCellGrid source,
  List<FocusInpaintPlan> plans,
) {
  final ownership = Uint8List(source.data.length);
  for (final plan in plans) {
    final repaintCells = plan.repaintCells;
    if (repaintCells == null || repaintCells.isEmpty) {
      throw StateError('AutoCrop produced a Focus request with no mask.');
    }
    for (var index = 0; index < ownership.length; index++) {
      if (repaintCells.data[index] == 0) continue;
      if (source.data[index] == 0 || ownership[index] != 0) {
        throw StateError('AutoCrop assigned a mask cell more than once.');
      }
      ownership[index] = 1;
    }
  }
  for (var index = 0; index < ownership.length; index++) {
    if ((source.data[index] > 0) != (ownership[index] > 0)) {
      throw StateError('AutoCrop did not assign every mask cell.');
    }
  }
}

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
  if (cells.isEmpty) return null;
  final cap = min(
    focusFrameMaxArea,
    max(minRequestSide * minRequestSide, maxArea),
  );

  final regions = _connectedMaskRegions(
    cells,
    imageWidth,
    imageHeight,
  );
  final ownedPlans = <_OwnedFocusPlan>[];
  var hasInternalSplit = false;
  FocusSplitMode singleRegionMode = FocusSplitMode.none;
  for (final region in regions) {
    final result = _planOwnedMaskRegion(
      region: region,
      cells: cells,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      maxArea: cap,
      contextPx: contextPx,
    );
    if (result == null) return null;
    ownedPlans.addAll(result.plans);
    if (result.splitMode != FocusSplitMode.none) hasInternalSplit = true;
    singleRegionMode = result.splitMode;
  }
  final mergedPlans = _mergeEquivalentFocusFrames(
    plans: ownedPlans,
    cells: cells,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    maxArea: cap,
    contextPx: contextPx,
  );
  if (mergedPlans.length > maxFocusTiles) {
    throw FocusInpaintTileLimitException(
      mergedPlans.length,
      maxFocusTiles,
    );
  }
  final tiles = mergedPlans
      .map(
        (owned) => _withOwnedCells(
          owned.geometry,
          _ownedCellGrid(owned.region, cells),
        ),
      )
      .toList(growable: false);
  _validateOwnedCoverage(cells, tiles);

  final splitMode = tiles.length <= 1
      ? FocusSplitMode.none
      : regions.length > 1
          ? hasInternalSplit
              ? FocusSplitMode.mixed
              : FocusSplitMode.islands
          : singleRegionMode;

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
