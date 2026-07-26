import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';

/// Composite instructions for pasting a focus-inpainting response back into
/// the original image: take [contentWidth] x [contentHeight] pixels at
/// ([contentOffsetX], [contentOffsetY]) out of the response, scale them back
/// to the outer frame, and draw that at the frame's position.
class AutocropCompositeInfo {
  final CropRect outer;
  final int contentOffsetX;
  final int contentOffsetY;
  final int contentWidth;
  final int contentHeight;
  final double scale;

  const AutocropCompositeInfo({
    required this.outer,
    required this.contentOffsetX,
    required this.contentOffsetY,
    required this.contentWidth,
    required this.contentHeight,
    required this.scale,
  });

  /// True when the content is the outer frame at 1:1 and needs no resampling.
  bool get isNativeScale => contentWidth == outer.w && contentHeight == outer.h;
}

/// Everything the payload builder needs for one img2img / infill request.
class I2iRequestPlan {
  final String imageB64;
  final String? maskB64;
  final int width;
  final int height;
  final double strength;
  final double noise;
  final bool addOriginalImage;

  /// Non-null when the response tile must be pasted back into the original.
  final AutocropCompositeInfo? composite;

  final String summary;

  const I2iRequestPlan({
    required this.imageB64,
    required this.maskB64,
    required this.width,
    required this.height,
    required this.strength,
    required this.noise,
    required this.addOriginalImage,
    required this.composite,
    required this.summary,
  });

  bool get isInpaint => maskB64 != null;
}

class _PlanCacheEntry {
  final int configId;
  final int revision;
  final int targetWidth;
  final int targetHeight;
  final I2iRequestPlan plan;

  const _PlanCacheEntry({
    required this.configId,
    required this.revision,
    required this.targetWidth,
    required this.targetHeight,
    required this.plan,
  });
}

/// Builds [I2iRequestPlan]s and composites autocrop responses.
///
/// Image decoding / encoding is expensive, so plans are cached per
/// (config revision, selected generation size) and reused across the
/// generation loop until the image, mask or relevant settings change.
class PrepareI2iRequestUseCase {
  final I2IConfig config;

  PrepareI2iRequestUseCase({required this.config});

  static final List<_PlanCacheEntry> _planCache = [];
  static const int _planCacheLimit = 4;

  static img.Image? _decodedBase;
  static int _decodedBaseConfigId = -1;
  static int _decodedBaseRevision = -1;
  static img.Image? _decodedMask;
  static int _decodedMaskConfigId = -1;
  static int _decodedMaskRevision = -1;

  static void clearCache() {
    _planCache.clear();
    _decodedBase = null;
    _decodedBaseConfigId = -1;
    _decodedBaseRevision = -1;
    _decodedMask = null;
    _decodedMaskConfigId = -1;
    _decodedMaskRevision = -1;
  }

  /// Builds (or returns a cached) request plan.
  ///
  /// [targetWidth] / [targetHeight] is the generation size selected for this
  /// request; plain img2img adapts the image to it, while inpainting derives
  /// its own request size and only uses it for the area-cap tier.
  Future<I2iRequestPlan?> call({
    required int targetWidth,
    required int targetHeight,
  }) async {
    if (!config.hasImage) return null;

    final configId = identityHashCode(config);
    for (final entry in _planCache) {
      if (entry.configId == configId &&
          entry.revision == config.revision &&
          entry.targetWidth == targetWidth &&
          entry.targetHeight == targetHeight) {
        return entry.plan;
      }
    }

    final plan = config.hasMask
        ? _buildInpaintPlan(targetWidth, targetHeight)
        : _buildImg2ImgPlan(targetWidth, targetHeight);
    _planCache.add(_PlanCacheEntry(
      configId: configId,
      revision: config.revision,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      plan: plan,
    ));
    while (_planCache.length > _planCacheLimit) {
      _planCache.removeAt(0);
    }
    return plan;
  }

  img.Image _requireBaseImage() {
    final configId = identityHashCode(config);
    if (_decodedBase != null &&
        _decodedBaseConfigId == configId &&
        _decodedBaseRevision == config.revision) {
      return _decodedBase!;
    }
    final decoded = img.decodeImage(config.imageBytes!);
    if (decoded == null) {
      throw Exception('Failed to decode img2img base image.');
    }
    final baked = img.bakeOrientation(decoded);
    _decodedBase = baked;
    _decodedBaseConfigId = configId;
    _decodedBaseRevision = config.revision;
    return baked;
  }

  img.Image _requireMaskImage() {
    final configId = identityHashCode(config);
    if (_decodedMask != null &&
        _decodedMaskConfigId == configId &&
        _decodedMaskRevision == config.revision) {
      return _decodedMask!;
    }
    final decoded = img.decodePng(config.maskBytes!);
    if (decoded == null) {
      throw Exception('Failed to decode inpainting mask.');
    }
    _decodedMask = decoded;
    _decodedMaskConfigId = configId;
    _decodedMaskRevision = config.revision;
    return decoded;
  }

  I2iRequestPlan _buildImg2ImgPlan(int targetWidth, int targetHeight) {
    final base = _requireBaseImage();
    String imageB64;
    if (base.width == targetWidth && base.height == targetHeight) {
      imageB64 = base64Encode(_pngBytesForOriginal(base));
    } else {
      // Cover-fit: scale to fill the target, then center-crop.
      final scale =
          max(targetWidth / base.width, targetHeight / base.height);
      final scaledW = max(targetWidth, (base.width * scale).round());
      final scaledH = max(targetHeight, (base.height * scale).round());
      var resized = img.copyResize(
        base,
        width: scaledW,
        height: scaledH,
        interpolation: img.Interpolation.cubic,
      );
      final cropX = ((scaledW - targetWidth) / 2).round();
      final cropY = ((scaledH - targetHeight) / 2).round();
      resized = img.copyCrop(
        resized,
        x: cropX,
        y: cropY,
        width: targetWidth,
        height: targetHeight,
      );
      imageB64 = base64Encode(img.encodePng(resized));
    }
    return I2iRequestPlan(
      imageB64: imageB64,
      maskB64: null,
      width: targetWidth,
      height: targetHeight,
      strength: config.strength,
      noise: config.noise,
      addOriginalImage: config.addOriginalImage,
      composite: null,
      summary: 'img2img ${base.width}x${base.height} -> '
          '${targetWidth}x$targetHeight, '
          'strength ${config.strength.toStringAsFixed(2)}, '
          'noise ${config.noise.toStringAsFixed(2)}',
    );
  }

  I2iRequestPlan _buildInpaintPlan(int targetWidth, int targetHeight) {
    final base = _requireBaseImage();
    final mask = _requireMaskImage();
    final cells = maskCellGridFromPixels(
      imageWidth: base.width,
      imageHeight: base.height,
      maskPixelAt: (x, y) => _maskPixelSet(mask, base.width, base.height, x, y),
    );
    if (cells.isEmpty) {
      throw Exception('Inpainting mask is empty; paint the repaint area first.');
    }
    final cap = areaCapForSize(targetWidth, targetHeight);

    if (config.autocropEnabled) {
      final plan = planFocusInpaint(
        imageWidth: base.width,
        imageHeight: base.height,
        cells: cells,
        maxArea: cap,
      );
      if (plan != null) {
        // Crop the outer frame, magnify it to content size, then center it on
        // the 64-aligned request canvas.
        var content = _cropWithPadding(base, plan.outer);
        if (plan.contentWidth != plan.outer.w ||
            plan.contentHeight != plan.outer.h) {
          content = img.copyResize(
            content,
            width: plan.contentWidth,
            height: plan.contentHeight,
            interpolation: img.Interpolation.cubic,
          );
        }
        final canvas = img.Image(
          width: plan.requestWidth,
          height: plan.requestHeight,
          numChannels: 3,
        );
        img.compositeImage(
          canvas,
          content,
          dstX: plan.contentOffsetX,
          dstY: plan.contentOffsetY,
        );
        final maskPng = _renderFocusMask(
          mask: mask,
          imageWidth: base.width,
          imageHeight: base.height,
          plan: plan,
        );
        return I2iRequestPlan(
          imageB64: base64Encode(img.encodePng(canvas)),
          maskB64: base64Encode(maskPng),
          width: plan.requestWidth,
          height: plan.requestHeight,
          strength: config.strength,
          noise: config.noise,
          addOriginalImage: config.addOriginalImage,
          composite: AutocropCompositeInfo(
            outer: plan.outer,
            contentOffsetX: plan.contentOffsetX,
            contentOffsetY: plan.contentOffsetY,
            contentWidth: plan.contentWidth,
            contentHeight: plan.contentHeight,
            scale: plan.scale,
          ),
          summary: 'inpaint focus: ${plan.describe()}, '
              'strength ${config.strength.toStringAsFixed(2)}',
        );
      }
      // Mask plus its context margin exceeds the budget: focus inpainting
      // refuses to shrink, so fall through to the whole-image path.
    }

    // Autocrop off, or the repaint area is too large to focus on: send the
    // whole image, scaled down to a compliant size.
    final requestSize = requestSizeForWindow(base.width, base.height, cap);
    final window = CropRect(x: 0, y: 0, w: base.width, h: base.height);
    img.Image whole = base;
    if (requestSize.x != base.width || requestSize.y != base.height) {
      whole = img.copyResize(
        base,
        width: requestSize.x,
        height: requestSize.y,
        interpolation: img.Interpolation.cubic,
      );
    }
    final maskPng = _renderRequestMask(
      mask: mask,
      imageWidth: base.width,
      imageHeight: base.height,
      window: window,
      requestWidth: requestSize.x,
      requestHeight: requestSize.y,
    );
    return I2iRequestPlan(
      imageB64: base64Encode(img.encodePng(whole)),
      maskB64: base64Encode(maskPng),
      width: requestSize.x,
      height: requestSize.y,
      strength: config.strength,
      noise: config.noise,
      addOriginalImage: config.addOriginalImage,
      composite: null,
      summary: 'inpaint whole image ${base.width}x${base.height} -> '
          '${requestSize.x}x${requestSize.y}, '
          'strength ${config.strength.toStringAsFixed(2)}',
    );
  }

  /// Renders the request-resolution mask for a focus plan: mask pixels are
  /// mapped through the outer frame and the content scale, quantized to the
  /// 8-px latent grid, and the padding around the content stays black.
  Uint8List _renderFocusMask({
    required img.Image mask,
    required int imageWidth,
    required int imageHeight,
    required FocusInpaintPlan plan,
  }) {
    final cellsW = (plan.requestWidth / maskCellSize).ceil();
    final cellsH = (plan.requestHeight / maskCellSize).ceil();
    final cells = Uint8List(cellsW * cellsH);
    final outer = plan.outer;
    for (var cy = 0; cy < cellsH; cy++) {
      final ry0 = cy * maskCellSize;
      final ry1 = min(plan.requestHeight, ry0 + maskCellSize);
      // Request space -> content space -> outer space -> image space.
      final cy0 = ry0 - plan.contentOffsetY;
      final cy1 = ry1 - plan.contentOffsetY;
      if (cy1 <= 0 || cy0 >= plan.contentHeight) continue;
      final oy0 = outer.y + (cy0 * outer.h / plan.contentHeight).floor();
      final oy1 = outer.y + (cy1 * outer.h / plan.contentHeight).ceil();
      final iy0 = max(0, oy0);
      final iy1 = min(imageHeight, oy1);
      if (iy1 <= iy0) continue;
      for (var cx = 0; cx < cellsW; cx++) {
        final rx0 = cx * maskCellSize;
        final rx1 = min(plan.requestWidth, rx0 + maskCellSize);
        final cx0 = rx0 - plan.contentOffsetX;
        final cx1 = rx1 - plan.contentOffsetX;
        if (cx1 <= 0 || cx0 >= plan.contentWidth) continue;
        final ox0 = outer.x + (cx0 * outer.w / plan.contentWidth).floor();
        final ox1 = outer.x + (cx1 * outer.w / plan.contentWidth).ceil();
        final ix0 = max(0, ox0);
        final ix1 = min(imageWidth, ox1);
        if (ix1 <= ix0) continue;
        var found = false;
        for (var y = iy0; y < iy1 && !found; y++) {
          for (var x = ix0; x < ix1; x++) {
            if (_maskPixelSet(mask, imageWidth, imageHeight, x, y)) {
              found = true;
              break;
            }
          }
        }
        if (found) cells[cy * cellsW + cx] = 1;
      }
    }

    final maskImage = img.Image(
      width: plan.requestWidth,
      height: plan.requestHeight,
      numChannels: 3,
    );
    for (var y = 0; y < plan.requestHeight; y++) {
      final cy = min(cellsH - 1, y ~/ maskCellSize);
      for (var x = 0; x < plan.requestWidth; x++) {
        final cx = min(cellsW - 1, x ~/ maskCellSize);
        if (cells[cy * cellsW + cx] > 0) {
          maskImage.setPixelRgb(x, y, 255, 255, 255);
        }
      }
    }
    return img.encodePng(maskImage);
  }

  /// Pastes the response tile back into the original image and returns the
  /// final PNG bytes (with the tile's stealth metadata re-embedded).
  Future<Uint8List> compositeResponse({
    required Uint8List responseBytes,
    required AutocropCompositeInfo composite,
  }) async {
    final base = _requireBaseImage();
    final response = img.decodePng(responseBytes);
    if (response == null) {
      throw Exception('Failed to decode generated tile for compositing.');
    }
    final outer = composite.outer;
    if (response.width < composite.contentOffsetX + composite.contentWidth ||
        response.height < composite.contentOffsetY + composite.contentHeight) {
      throw Exception(
        'Response ${response.width}x${response.height} is smaller than the '
        'planned content area; cannot composite.',
      );
    }

    // Cut the content out of the request canvas, then scale it back to the
    // outer frame's own resolution.
    var content = img.copyCrop(
      response,
      x: composite.contentOffsetX,
      y: composite.contentOffsetY,
      width: composite.contentWidth,
      height: composite.contentHeight,
    );
    if (!composite.isNativeScale) {
      content = img.copyResize(
        content,
        width: outer.w,
        height: outer.h,
        interpolation: img.Interpolation.cubic,
      );
    }

    final canvas = img.Image.from(base);
    _pasteIntersection(canvas, content, outer);

    var output = canvas;
    if (output.numChannels != 4) {
      output = output.convert(numChannels: 4);
    }
    var pngBytes = img.encodePng(output);

    // Preserve the server's stealth metadata so imports keep working.
    try {
      final metadataString = await ImageService().extractMetadata(response);
      if (metadataString != null) {
        pngBytes = await ImageService().embedMetadata(pngBytes, metadataString);
      }
    } catch (_) {
      // Metadata is best-effort; the composed image itself matters more.
    }
    return pngBytes;
  }

  Uint8List _pngBytesForOriginal(img.Image base) {
    final raw = config.imageBytes!;
    // Reuse the original bytes when they are already a PNG.
    if (raw.length > 8 &&
        raw[0] == 0x89 &&
        raw[1] == 0x50 &&
        raw[2] == 0x4E &&
        raw[3] == 0x47) {
      return raw;
    }
    return img.encodePng(base);
  }

  bool _maskPixelSet(img.Image mask, int imageW, int imageH, int x, int y) {
    // The mask is stored at image resolution; guard against size drift.
    final mx = mask.width == imageW
        ? x
        : ((x * mask.width) / imageW).floor().clamp(0, mask.width - 1);
    final my = mask.height == imageH
        ? y
        : ((y * mask.height) / imageH).floor().clamp(0, mask.height - 1);
    final pixel = mask.getPixel(mx, my);
    return pixel.r > 127;
  }

  /// Crop [window] out of [src]; areas outside the image are padded black.
  img.Image _cropWithPadding(img.Image src, CropRect window) {
    final canvas = img.Image(
      width: window.w,
      height: window.h,
      numChannels: 3,
    );
    final ix = max(0, window.x);
    final iy = max(0, window.y);
    final iRight = min(src.width, window.right);
    final iBottom = min(src.height, window.bottom);
    if (iRight <= ix || iBottom <= iy) return canvas;
    final cropped = img.copyCrop(
      src,
      x: ix,
      y: iy,
      width: iRight - ix,
      height: iBottom - iy,
    );
    img.compositeImage(
      canvas,
      cropped,
      dstX: ix - window.x,
      dstY: iy - window.y,
    );
    return canvas;
  }

  /// Renders the request-resolution mask PNG (white = repaint), quantized to
  /// the server's 8-px cells like the official web editor.
  Uint8List _renderRequestMask({
    required img.Image mask,
    required int imageWidth,
    required int imageHeight,
    required CropRect window,
    required int requestWidth,
    required int requestHeight,
  }) {
    final cellsW = (requestWidth / maskCellSize).ceil();
    final cellsH = (requestHeight / maskCellSize).ceil();
    final cells = Uint8List(cellsW * cellsH);
    for (var cy = 0; cy < cellsH; cy++) {
      final ry0 = cy * maskCellSize;
      final ry1 = min(requestHeight, ry0 + maskCellSize);
      // Map request rows back to window rows, then to image rows.
      final wy0 = window.y + (ry0 * window.h / requestHeight).floor();
      final wy1 = window.y + (ry1 * window.h / requestHeight).ceil();
      final iy0 = max(0, wy0);
      final iy1 = min(imageHeight, wy1);
      for (var cx = 0; cx < cellsW; cx++) {
        final rx0 = cx * maskCellSize;
        final rx1 = min(requestWidth, rx0 + maskCellSize);
        final wx0 = window.x + (rx0 * window.w / requestWidth).floor();
        final wx1 = window.x + (rx1 * window.w / requestWidth).ceil();
        final ix0 = max(0, wx0);
        final ix1 = min(imageWidth, wx1);
        var found = false;
        for (var y = iy0; y < iy1 && !found; y++) {
          for (var x = ix0; x < ix1; x++) {
            if (_maskPixelSet(mask, imageWidth, imageHeight, x, y)) {
              found = true;
              break;
            }
          }
        }
        if (found) cells[cy * cellsW + cx] = 1;
      }
    }

    final maskImage = img.Image(
      width: requestWidth,
      height: requestHeight,
      numChannels: 3,
    );
    for (var y = 0; y < requestHeight; y++) {
      final cy = min(cellsH - 1, y ~/ maskCellSize);
      for (var x = 0; x < requestWidth; x++) {
        final cx = min(cellsW - 1, x ~/ maskCellSize);
        if (cells[cy * cellsW + cx] > 0) {
          maskImage.setPixelRgb(x, y, 255, 255, 255);
        }
      }
    }
    return img.encodePng(maskImage);
  }

  /// 1:1 paste of the tile onto the canvas at the window position, clipped to
  /// the image bounds. Valid because add_original_image keeps unmasked pixels
  /// identical to the input tile.
  void _pasteIntersection(img.Image canvas, img.Image tile, CropRect window) {
    final ix = max(0, window.x);
    final iy = max(0, window.y);
    final iRight = min(canvas.width, window.right);
    final iBottom = min(canvas.height, window.bottom);
    if (iRight <= ix || iBottom <= iy) return;
    final srcX = ix - window.x;
    final srcY = iy - window.y;
    final w = min(iRight - ix, tile.width - srcX);
    final h = min(iBottom - iy, tile.height - srcY);
    if (w <= 0 || h <= 0) return;
    final srcPart = img.copyCrop(
      tile,
      x: srcX,
      y: srcY,
      width: w,
      height: h,
    );
    img.compositeImage(canvas, srcPart, dstX: ix, dstY: iy);
  }
}
