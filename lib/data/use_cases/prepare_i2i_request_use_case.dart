import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/i2i_config.dart';
import 'package:nai_casrand/data/services/image_service.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';

class _PlainI2iPrepareInput {
  final Uint8List imageBytes;
  final int sourceWidth;
  final int sourceHeight;
  final int targetWidth;
  final int targetHeight;
  final double strength;
  final double noise;
  final bool addOriginalImage;

  const _PlainI2iPrepareInput({
    required this.imageBytes,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.targetWidth,
    required this.targetHeight,
    required this.strength,
    required this.noise,
    required this.addOriginalImage,
  });
}

class _EncodedInpaintMasks {
  final Uint8List request;
  final Uint8List blend;

  const _EncodedInpaintMasks({required this.request, required this.blend});
}

I2iRequestPlan _preparePlainI2iPlan(_PlainI2iPrepareInput input) {
  return I2iRequestPlan(
    imageB64: base64Encode(input.imageBytes),
    maskB64: null,
    blendMaskB64: null,
    width: input.targetWidth,
    height: input.targetHeight,
    strength: input.strength,
    noise: input.noise,
    addOriginalImage: input.addOriginalImage,
    composite: null,
    summary: 'img2img ${input.sourceWidth}x${input.sourceHeight} -> '
        '${input.targetWidth}x${input.targetHeight}, '
        'strength ${input.strength.toStringAsFixed(2)}, '
        'noise ${input.noise.toStringAsFixed(2)}',
  );
}

Future<I2iRequestPlan> preparePlainImg2ImgBytesInBackground({
  required Uint8List imageBytes,
  required int sourceWidth,
  required int sourceHeight,
  required int targetWidth,
  required int targetHeight,
  required double strength,
  required double noise,
  required bool addOriginalImage,
}) {
  return compute(
    _preparePlainI2iPlan,
    _PlainI2iPrepareInput(
      imageBytes: imageBytes,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      strength: strength,
      noise: noise,
      addOriginalImage: addOriginalImage,
    ),
    debugLabel: 'prepare-plain-img2img',
  );
}

class _FocusPreviewInput {
  final Uint8List? maskBytes;
  final int imageWidth;
  final int imageHeight;
  final int maxArea;
  final int contextPx;
  final bool autocropEnabled;
  final CropRect? manualFrame;

  const _FocusPreviewInput({
    required this.maskBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.maxArea,
    required this.contextPx,
    required this.autocropEnabled,
    required this.manualFrame,
  });
}

FocusInpaintBatch? _planFocusPreview(_FocusPreviewInput input) {
  MaskCellGrid? cells;
  final maskBytes = input.maskBytes;
  if (maskBytes != null) {
    final mask = img.decodePng(maskBytes) ?? img.decodeImage(maskBytes);
    if (mask == null) return null;
    cells = maskCellGridFromPixels(
      imageWidth: input.imageWidth,
      imageHeight: input.imageHeight,
      maskPixelAt: (x, y) {
        final mx = mask.width == input.imageWidth
            ? x
            : ((x * mask.width) / input.imageWidth)
                .floor()
                .clamp(0, mask.width - 1);
        final my = mask.height == input.imageHeight
            ? y
            : ((y * mask.height) / input.imageHeight)
                .floor()
                .clamp(0, mask.height - 1);
        return mask.getPixel(mx, my).r > 127;
      },
    );
    if (cells.isEmpty) return null;
  }
  final manual = input.manualFrame;
  if (manual != null) {
    final plan = planManualFocusInpaint(
      imageWidth: input.imageWidth,
      imageHeight: input.imageHeight,
      cells: cells,
      frame: manual,
      maxArea: input.maxArea,
      contextPx: input.contextPx,
    );
    if (plan != null) {
      return FocusInpaintBatch(
        tiles: [plan],
        splitMode: FocusSplitMode.none,
        serial: true,
      );
    }
  }
  if (cells == null) return null;
  if (!input.autocropEnabled ||
      !autocropAppliesToImage(input.imageWidth, input.imageHeight)) {
    return null;
  }
  return planFocusInpaintBatch(
    imageWidth: input.imageWidth,
    imageHeight: input.imageHeight,
    cells: cells,
    maxArea: input.maxArea,
    contextPx: input.contextPx,
  );
}

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

  /// Full request-size, opaque black/white mask sent to NovelAI.
  final String? maskB64;

  /// Transparent/white 1/8 latent mask used only for local feathering.
  final String? blendMaskB64;
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
    this.blendMaskB64,
    required this.width,
    required this.height,
    required this.strength,
    required this.noise,
    required this.addOriginalImage,
    required this.composite,
    required this.summary,
  });

  bool get isInpaint => maskB64 != null;

  I2iRequestPlan withRequestParameters({
    required double strength,
    required double noise,
    required bool addOriginalImage,
  }) {
    final parameterText = isInpaint
        ? 'strength ${strength.toStringAsFixed(2)}'
        : 'strength ${strength.toStringAsFixed(2)}, '
            'noise ${noise.toStringAsFixed(2)}';
    return I2iRequestPlan(
      imageB64: imageB64,
      maskB64: maskB64,
      blendMaskB64: blendMaskB64,
      width: width,
      height: height,
      strength: strength,
      noise: noise,
      addOriginalImage: addOriginalImage,
      composite: composite,
      summary: summary.replaceFirst(
        RegExp(r'strength \d+(?:\.\d+)?(?:, noise \d+(?:\.\d+)?)?$'),
        parameterText,
      ),
    );
  }
}

/// One inpainting generation: a single request, or several focus tiles that
/// are composited onto the same canvas.
class I2iRequestBatch {
  final List<I2iRequestPlan> plans;

  /// Original full-resolution source used to seed local focus-inpaint
  /// compositing. Keeping it on the batch makes an in-flight request
  /// independent from later edits to the mutable [I2IConfig].
  final String? compositeBaseImageB64;

  /// Tiles must be sent one after another (overlapping frames).
  final bool serial;

  final String summary;

  const I2iRequestBatch({
    required this.plans,
    this.compositeBaseImageB64,
    required this.serial,
    required this.summary,
  });

  bool get isSplit => plans.length > 1;
  int get tileCount => plans.length;
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

class _BatchCacheEntry {
  final int configId;
  final int revision;
  final int targetWidth;
  final int targetHeight;
  final I2iRequestBatch batch;

  const _BatchCacheEntry({
    required this.configId,
    required this.revision,
    required this.targetWidth,
    required this.targetHeight,
    required this.batch,
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
  static final List<_BatchCacheEntry> _batchCache = [];
  static const int _planCacheLimit = 4;

  static img.Image? _decodedBase;
  static int _decodedBaseConfigId = -1;
  static int _decodedBaseRevision = -1;
  static img.Image? _decodedMask;
  static int _decodedMaskConfigId = -1;
  static int _decodedMaskRevision = -1;

  static void clearCache() {
    _planCache.clear();
    _batchCache.clear();
    _decodedBase = null;
    _decodedBaseConfigId = -1;
    _decodedBaseRevision = -1;
    _decodedMask = null;
    _decodedMaskConfigId = -1;
    _decodedMaskRevision = -1;
  }

  /// Plans only the visible focus frames. It decodes the mask on a background
  /// isolate and skips base-image cropping/PNG encoding, so the page can show
  /// Autocrop immediately without blocking slider interaction.
  Future<FocusInpaintBatch?> planFocusPreview({
    required int targetWidth,
    required int targetHeight,
  }) async {
    if (!config.hasImage || !config.hasInpaintSelection) return null;
    return compute(
      _planFocusPreview,
      _FocusPreviewInput(
        maskBytes: config.maskBytes,
        imageWidth: config.width,
        imageHeight: config.height,
        maxArea: areaCapForSize(targetWidth, targetHeight),
        contextPx: config.contextPx,
        autocropEnabled: config.autocropEnabled,
        manualFrame: config.manualFocusFrame,
      ),
      debugLabel: 'plan-inpaint-focus-preview',
    );
  }

  /// Builds the full request batch for one generation: a single img2img /
  /// inpaint request, or several focus tiles when the mask needs splitting.
  Future<I2iRequestBatch?> planBatch({
    required int targetWidth,
    required int targetHeight,
  }) async {
    while (config.hasImage) {
      final configId = identityHashCode(config);
      final revision = config.planRevision;
      for (final entry in _batchCache) {
        if (entry.configId == configId &&
            entry.revision == revision &&
            entry.targetWidth == targetWidth &&
            entry.targetHeight == targetHeight) {
          return _withCurrentParameters(entry.batch);
        }
      }

      late final I2iRequestBatch batch;
      if (!config.hasInpaintSelection) {
        final plan = await call(
          targetWidth: targetWidth,
          targetHeight: targetHeight,
        );
        if (plan == null) return null;
        batch = I2iRequestBatch(
          plans: [plan],
          serial: true,
          summary: plan.summary,
        );
      } else {
        batch = _buildInpaintBatch(targetWidth, targetHeight);
      }
      if (identityHashCode(config) != configId ||
          config.planRevision != revision) {
        continue;
      }
      _batchCache.add(_BatchCacheEntry(
        configId: configId,
        revision: revision,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        batch: batch,
      ));
      while (_batchCache.length > _planCacheLimit) {
        _batchCache.removeAt(0);
      }
      return _withCurrentParameters(batch);
    }
    return null;
  }

  I2iRequestBatch _withCurrentParameters(I2iRequestBatch batch) {
    final plans = batch.plans
        .map(
          (plan) => plan.withRequestParameters(
            strength: config.strength,
            noise: config.noise,
            addOriginalImage: config.addOriginalImage,
          ),
        )
        .toList(growable: false);
    return I2iRequestBatch(
      plans: plans,
      compositeBaseImageB64: batch.compositeBaseImageB64,
      serial: batch.serial,
      summary: batch.isSplit ? batch.summary : plans.first.summary,
    );
  }

  /// Builds (or returns a cached) single request plan. For a split mask this
  /// returns the first tile only; use [planBatch] for the whole batch.
  ///
  /// [targetWidth] / [targetHeight] is the generation size selected for this
  /// request; plain img2img preserves the source bytes while requesting those
  /// output dimensions, while inpainting derives its own request size.
  Future<I2iRequestPlan?> call({
    required int targetWidth,
    required int targetHeight,
  }) async {
    while (config.hasImage) {
      final configId = identityHashCode(config);
      final revision = config.planRevision;
      for (final entry in _planCache) {
        if (entry.configId == configId &&
            entry.revision == revision &&
            entry.targetWidth == targetWidth &&
            entry.targetHeight == targetHeight) {
          return entry.plan.withRequestParameters(
            strength: config.strength,
            noise: config.noise,
            addOriginalImage: config.addOriginalImage,
          );
        }
      }

      final plan = config.hasInpaintSelection
          ? _buildInpaintBatch(targetWidth, targetHeight).plans.first
          : await preparePlainImg2ImgBytesInBackground(
              imageBytes: config.imageBytes!,
              sourceWidth: config.width,
              sourceHeight: config.height,
              targetWidth: targetWidth,
              targetHeight: targetHeight,
              strength: config.strength,
              noise: config.noise,
              addOriginalImage: config.addOriginalImage,
            );
      if (identityHashCode(config) != configId ||
          config.planRevision != revision) {
        continue;
      }
      _planCache.add(_PlanCacheEntry(
        configId: configId,
        revision: revision,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        plan: plan,
      ));
      while (_planCache.length > _planCacheLimit) {
        _planCache.removeAt(0);
      }
      return plan.withRequestParameters(
        strength: config.strength,
        noise: config.noise,
        addOriginalImage: config.addOriginalImage,
      );
    }
    return null;
  }

  img.Image _requireBaseImage() {
    final configId = identityHashCode(config);
    if (_decodedBase != null &&
        _decodedBaseConfigId == configId &&
        _decodedBaseRevision == config.planRevision) {
      return _decodedBase!;
    }
    final decoded = img.decodeImage(config.imageBytes!);
    if (decoded == null) {
      throw Exception('Failed to decode img2img base image.');
    }
    final baked = img.bakeOrientation(decoded);
    _decodedBase = baked;
    _decodedBaseConfigId = configId;
    _decodedBaseRevision = config.planRevision;
    return baked;
  }

  img.Image _requireMaskImage() {
    final configId = identityHashCode(config);
    if (_decodedMask != null &&
        _decodedMaskConfigId == configId &&
        _decodedMaskRevision == config.planRevision) {
      return _decodedMask!;
    }
    final decoded = img.decodePng(config.maskBytes!);
    if (decoded == null) {
      throw Exception('Failed to decode inpainting mask.');
    }
    _decodedMask = decoded;
    _decodedMaskConfigId = configId;
    _decodedMaskRevision = config.planRevision;
    return decoded;
  }

  /// Builds one focus tile request from its plan.
  I2iRequestPlan _buildFocusTile({
    required img.Image base,
    required img.Image? mask,
    required FocusInpaintPlan plan,
    required String label,
  }) {
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
    final masks = _renderFocusMasks(
      mask: mask,
      imageWidth: base.width,
      imageHeight: base.height,
      plan: plan,
    );
    return I2iRequestPlan(
      imageB64: base64Encode(img.encodePng(canvas)),
      maskB64: base64Encode(masks.request),
      blendMaskB64: base64Encode(masks.blend),
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
      summary: 'inpaint focus$label: ${plan.describe()}, '
          'strength ${config.strength.toStringAsFixed(2)}',
    );
  }

  I2iRequestBatch _buildInpaintBatch(int targetWidth, int targetHeight) {
    final base = _requireBaseImage();
    final compositeBaseImageB64 = base64Encode(_pngBytesForOriginal(base));
    final mask = config.hasMask ? _requireMaskImage() : null;
    MaskCellGrid? cells;
    if (mask != null) {
      cells = maskCellGridFromPixels(
        imageWidth: base.width,
        imageHeight: base.height,
        maskPixelAt: (x, y) =>
            _maskPixelSet(mask, base.width, base.height, x, y),
      );
      if (cells.isEmpty) {
        throw Exception(
            'Inpainting mask is empty; paint the repaint area first.');
      }
    }
    final cap = areaCapForSize(targetWidth, targetHeight);

    // A hand-drawn focus frame overrides the automatic search. With no mask,
    // NovelAI repaints the whole inner region and keeps the Context Region.
    // With a mask, only painted pixels inside the frame are repainted.
    final manualFrame = config.manualFocusFrame;
    if (manualFrame != null) {
      final plan = planManualFocusInpaint(
        imageWidth: base.width,
        imageHeight: base.height,
        cells: cells,
        frame: manualFrame,
        maxArea: cap,
        contextPx: config.contextPx,
      );
      if (plan != null) {
        final tile = _buildFocusTile(
          base: base,
          mask: mask,
          plan: plan,
          label: ' manual',
        );
        return I2iRequestBatch(
          plans: [tile],
          compositeBaseImageB64: compositeBaseImageB64,
          serial: true,
          summary: tile.summary,
        );
      }
    }

    if (mask == null || cells == null) {
      throw Exception(
          'Maskless inpainting requires a valid manual Focus frame.');
    }

    if (config.autocropEnabled &&
        autocropAppliesToImage(base.width, base.height)) {
      final batch = planFocusInpaintBatch(
        imageWidth: base.width,
        imageHeight: base.height,
        cells: cells,
        maxArea: cap,
        contextPx: config.contextPx,
      );
      if (batch != null) {
        final plans = <I2iRequestPlan>[];
        for (final (index, tile) in batch.tiles.indexed) {
          plans.add(_buildFocusTile(
            base: base,
            mask: mask,
            plan: tile,
            label: batch.isSplit ? ' ${index + 1}/${batch.tileCount}' : '',
          ));
        }
        final modeText = switch (batch.splitMode) {
          FocusSplitMode.grid => 'grid split',
          FocusSplitMode.longAxis => 'long-axis split',
          FocusSplitMode.islands => 'mask islands',
          FocusSplitMode.mixed => 'mixed island split',
          FocusSplitMode.none => 'single frame',
        };
        return I2iRequestBatch(
          plans: plans,
          compositeBaseImageB64: compositeBaseImageB64,
          serial: batch.serial,
          summary: batch.isSplit
              ? 'inpaint focus, $modeText into ${batch.tileCount} tiles '
                  '(${batch.serial ? 'serial' : 'concurrent'})'
              : plans.first.summary,
        );
      }
      // Mask plus its context margin exceeds the budget: focus inpainting
      // refuses to shrink, so fall through to the whole-image path.
    }

    // Autocrop off/inactive, or the repaint area is too large to focus on:
    // send the whole image, scaled down to a compliant size.
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
    final masks = _renderRequestMasks(
      mask: mask,
      imageWidth: base.width,
      imageHeight: base.height,
      window: window,
      requestWidth: requestSize.x,
      requestHeight: requestSize.y,
    );
    final wholePlan = I2iRequestPlan(
      imageB64: base64Encode(img.encodePng(whole)),
      maskB64: base64Encode(masks.request),
      blendMaskB64: base64Encode(masks.blend),
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
    return I2iRequestBatch(
      plans: [wholePlan],
      serial: true,
      summary: wholePlan.summary,
    );
  }

  /// Renders the request-resolution mask for a focus plan: mask pixels are
  /// mapped through the outer frame and the content scale, quantized to the
  /// 8-px latent grid, and the padding around the content stays black.
  _EncodedInpaintMasks _renderFocusMasks({
    required img.Image? mask,
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
            if (x < plan.inner.x ||
                x >= plan.inner.right ||
                y < plan.inner.y ||
                y >= plan.inner.bottom) {
              continue;
            }
            final repaintCells = plan.repaintCells;
            if (repaintCells != null &&
                !repaintCells.cellAt(
                  x ~/ maskCellSize,
                  y ~/ maskCellSize,
                )) {
              continue;
            }
            if (mask == null ||
                _maskPixelSet(mask, imageWidth, imageHeight, x, y)) {
              found = true;
              break;
            }
          }
        }
        if (found) cells[cy * cellsW + cx] = 1;
      }
    }

    return _encodeInpaintMasks(
      cells,
      cellsW,
      cellsH,
      plan.requestWidth,
      plan.requestHeight,
    );
  }

  /// Blends one infill response over its request source using the same
  /// expanded, feathered latent mask as the official frontend.
  Future<Uint8List> compositeInpaintResponse({
    required Uint8List responseBytes,
    required I2iRequestPlan plan,
    String? compositeBaseImageB64,
  }) async {
    if (!plan.isInpaint) {
      throw ArgumentError('The request plan is not an infill request.');
    }
    final canvas = plan.composite == null
        ? _decodeRequestImage(plan)
        : newCompositeCanvas(baseImageB64: compositeBaseImageB64);
    blendInpaintTileInto(
      canvas: canvas,
      responseBytes: responseBytes,
      plan: plan,
    );
    return finishComposite(canvas: canvas, responseBytes: responseBytes);
  }

  /// Rebuilds a Focus request source from the current composite canvas. This
  /// makes a later overlapping serial tile observe earlier repaint results
  /// while preserving the batch's frozen prompt and generation parameters.
  I2iRequestPlan rebaseFocusPlanOnCanvas({
    required img.Image canvas,
    required I2iRequestPlan plan,
  }) {
    final composite = plan.composite;
    if (composite == null) return plan;
    var content = _cropWithPadding(canvas, composite.outer);
    if (content.width != composite.contentWidth ||
        content.height != composite.contentHeight) {
      content = img.copyResize(
        content,
        width: composite.contentWidth,
        height: composite.contentHeight,
        interpolation: img.Interpolation.cubic,
      );
    }
    final requestCanvas = img.Image(
      width: plan.width,
      height: plan.height,
      numChannels: 3,
    );
    img.compositeImage(
      requestCanvas,
      content,
      dstX: composite.contentOffsetX,
      dstY: composite.contentOffsetY,
    );
    return I2iRequestPlan(
      imageB64: base64Encode(img.encodePng(requestCanvas)),
      maskB64: plan.maskB64,
      blendMaskB64: plan.blendMaskB64,
      width: plan.width,
      height: plan.height,
      strength: plan.strength,
      noise: plan.noise,
      addOriginalImage: plan.addOriginalImage,
      composite: composite,
      summary: plan.summary,
    );
  }

  /// Blends one focus tile onto [canvas] in place, so a split mask accumulates
  /// all of its softly feathered tiles onto the same image.
  void blendInpaintTileInto({
    required img.Image canvas,
    required Uint8List responseBytes,
    required I2iRequestPlan plan,
  }) {
    final response = img.decodePng(responseBytes);
    if (response == null) {
      throw Exception('Failed to decode generated tile for compositing.');
    }
    if (!plan.isInpaint) {
      throw ArgumentError('The request plan is not an infill request.');
    }
    if (response.width != plan.width || response.height != plan.height) {
      throw Exception(
        'Response ${response.width}x${response.height} does not match the '
        'planned infill size ${plan.width}x${plan.height}.',
      );
    }

    final featheredMask = _buildOfficialBlendAlpha(plan);
    var maskedResponse = _applyAlphaMask(response, featheredMask);
    final composite = plan.composite;
    if (composite == null) {
      if (canvas.width != maskedResponse.width ||
          canvas.height != maskedResponse.height) {
        throw Exception(
          'The infill source canvas does not match the response size.',
        );
      }
      img.compositeImage(canvas, maskedResponse);
      return;
    }

    final outer = composite.outer;
    if (maskedResponse.width <
            composite.contentOffsetX + composite.contentWidth ||
        maskedResponse.height <
            composite.contentOffsetY + composite.contentHeight) {
      throw Exception(
        'Response ${response.width}x${response.height} is smaller than the '
        'planned content area; cannot composite.',
      );
    }

    // Cut the content out of the request canvas, then scale it back to the
    // outer frame's own resolution.
    var content = img.copyCrop(
      maskedResponse,
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

    _pasteIntersection(canvas, content, outer);
  }

  img.Image _decodeRequestImage(I2iRequestPlan plan) {
    final decoded = img.decodePng(base64Decode(plan.imageB64)) ??
        img.decodeImage(base64Decode(plan.imageB64));
    if (decoded == null) {
      throw Exception('Failed to decode the infill request source image.');
    }
    return img.Image.from(decoded);
  }

  Uint8List _buildOfficialBlendAlpha(I2iRequestPlan plan) {
    final blendMaskB64 = plan.blendMaskB64;
    if (blendMaskB64 == null) {
      throw Exception('Infill plan is missing its local blend mask.');
    }
    final maskBytes = base64Decode(blendMaskB64);
    final latent = img.decodePng(maskBytes) ?? img.decodeImage(maskBytes);
    if (latent == null) {
      throw Exception('Failed to decode the infill request mask.');
    }
    final expectedWidth = (plan.width / maskCellSize).ceil();
    final expectedHeight = (plan.height / maskCellSize).ceil();
    if (latent.width != expectedWidth || latent.height != expectedHeight) {
      throw Exception(
        'Infill mask ${latent.width}x${latent.height} does not match the '
        'expected latent size ${expectedWidth}x$expectedHeight.',
      );
    }

    const dilationRadius = 4;
    final dilated = Uint8List(latent.width * latent.height);
    for (var y = 0; y < latent.height; y++) {
      for (var x = 0; x < latent.width; x++) {
        final pixel = latent.getPixel(x, y);
        if (pixel.a <= 155 || pixel.r <= 155) continue;
        final y0 = max(0, y - dilationRadius);
        final y1 = min(latent.height - 1, y + dilationRadius);
        final x0 = max(0, x - dilationRadius);
        final x1 = min(latent.width - 1, x + dilationRadius);
        for (var dy = y0; dy <= y1; dy++) {
          final row = dy * latent.width;
          for (var dx = x0; dx <= x1; dx++) {
            dilated[row + dx] = 255;
          }
        }
      }
    }

    var scaled = Uint8List(plan.width * plan.height);
    for (var y = 0; y < plan.height; y++) {
      final sourceY = min(latent.height - 1, y ~/ maskCellSize);
      final sourceRow = sourceY * latent.width;
      final outputRow = y * plan.width;
      for (var x = 0; x < plan.width; x++) {
        final sourceX = min(latent.width - 1, x ~/ maskCellSize);
        scaled[outputRow + x] = dilated[sourceRow + sourceX];
      }
    }

    // The website worker applies radius-20 blur twice. A sliding-window blur
    // keeps this linear in pixel count, which matters for 1 MP focus tiles.
    scaled = _boxBlurAlpha(scaled, plan.width, plan.height, 20);
    return _boxBlurAlpha(scaled, plan.width, plan.height, 20);
  }

  Uint8List _boxBlurAlpha(
    Uint8List source,
    int width,
    int height,
    int radius,
  ) {
    final window = radius * 2 + 1;
    final horizontal = Uint8List(source.length);
    final output = Uint8List(source.length);

    for (var y = 0; y < height; y++) {
      final row = y * width;
      var sum = 0;
      for (var offset = -radius; offset <= radius; offset++) {
        sum += source[row + offset.clamp(0, width - 1)];
      }
      for (var x = 0; x < width; x++) {
        horizontal[row + x] = (sum / window).round();
        final removeX = (x - radius).clamp(0, width - 1);
        final addX = (x + radius + 1).clamp(0, width - 1);
        sum += source[row + addX] - source[row + removeX];
      }
    }

    for (var x = 0; x < width; x++) {
      var sum = 0;
      for (var offset = -radius; offset <= radius; offset++) {
        final sourceY = offset.clamp(0, height - 1);
        sum += horizontal[sourceY * width + x];
      }
      for (var y = 0; y < height; y++) {
        output[y * width + x] = (sum / window).round();
        final removeY = (y - radius).clamp(0, height - 1);
        final addY = (y + radius + 1).clamp(0, height - 1);
        sum += horizontal[addY * width + x] - horizontal[removeY * width + x];
      }
    }
    return output;
  }

  img.Image _applyAlphaMask(img.Image response, Uint8List mask) {
    final output = response.convert(numChannels: 4);
    for (var y = 0; y < output.height; y++) {
      for (var x = 0; x < output.width; x++) {
        final source = output.getPixel(x, y);
        final alpha =
            (source.a.toInt() * mask[y * output.width + x] / 255).round();
        output.setPixelRgba(
          x,
          y,
          source.r,
          source.g,
          source.b,
          alpha,
        );
      }
    }
    return output;
  }

  /// A canvas seeded with the batch's immutable base image snapshot, ready for
  /// [blendInpaintTileInto]. The config fallback keeps direct use-case callers
  /// compatible, while generation always supplies the captured batch image.
  img.Image newCompositeCanvas({String? baseImageB64}) {
    if (baseImageB64 == null) return img.Image.from(_requireBaseImage());
    final bytes = base64Decode(baseImageB64);
    final decoded = img.decodePng(bytes) ?? img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Failed to decode the inpaint composite base image.');
    }
    return img.Image.from(img.bakeOrientation(decoded));
  }

  /// Encodes the finished canvas, re-embedding the response's stealth
  /// metadata so imports keep working.
  Future<Uint8List> finishComposite({
    required img.Image canvas,
    required Uint8List responseBytes,
  }) async {
    var output = canvas;
    if (output.numChannels != 4) {
      output = output.convert(numChannels: 4);
    }
    var pngBytes = img.encodePng(output);
    try {
      final response = img.decodePng(responseBytes);
      final metadataString = response == null
          ? null
          : await ImageService().extractMetadata(response);
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
  _EncodedInpaintMasks _renderRequestMasks({
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

    return _encodeInpaintMasks(
      cells,
      cellsW,
      cellsH,
      requestWidth,
      requestHeight,
    );
  }

  _EncodedInpaintMasks _encodeInpaintMasks(
    Uint8List cells,
    int cellsWidth,
    int cellsHeight,
    int requestWidth,
    int requestHeight,
  ) {
    final blendMask = img.Image(
      width: cellsWidth,
      height: cellsHeight,
      numChannels: 4,
    );
    final requestMask = img.Image(
      width: requestWidth,
      height: requestHeight,
      numChannels: 3,
    );
    img.fill(requestMask, color: img.ColorRgb8(0, 0, 0));
    for (var y = 0; y < cellsHeight; y++) {
      for (var x = 0; x < cellsWidth; x++) {
        if (cells[y * cellsWidth + x] > 0) {
          blendMask.setPixelRgba(x, y, 255, 255, 255, 255);
          final x1 = x * maskCellSize;
          final y1 = y * maskCellSize;
          final x2 = min(requestWidth, x1 + maskCellSize) - 1;
          final y2 = min(requestHeight, y1 + maskCellSize) - 1;
          if (x2 >= x1 && y2 >= y1) {
            img.fillRect(
              requestMask,
              x1: x1,
              y1: y1,
              x2: x2,
              y2: y2,
              color: img.ColorRgb8(255, 255, 255),
            );
          }
        } else {
          blendMask.setPixelRgba(x, y, 0, 0, 0, 0);
        }
      }
    }
    return _EncodedInpaintMasks(
      request: Uint8List.fromList(img.encodePng(requestMask)),
      blend: Uint8List.fromList(img.encodePng(blendMask)),
    );
  }

  /// Alpha-composites a tile at the window position, clipped to image bounds.
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
