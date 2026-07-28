import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/use_cases/autocrop_planner.dart';

MaskCellGrid gridWithMaskRect({
  required int imageWidth,
  required int imageHeight,
  required Rectangle<int> maskRect,
}) {
  return maskCellGridFromPixels(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    maskPixelAt: (x, y) =>
        x >= maskRect.left &&
        x < maskRect.left + maskRect.width &&
        y >= maskRect.top &&
        y < maskRect.top + maskRect.height,
  );
}

/// Every plan must satisfy the focus-inpainting invariants.
void expectValidPlan(
  FocusInpaintPlan plan, {
  required int imageWidth,
  required int imageHeight,
  required int cap,
}) {
  // Scale never shrinks the frame.
  expect(plan.scale, greaterThanOrEqualTo(1.0),
      reason: 'focus inpainting never shrinks');
  // Request canvas is 64-aligned and inside the budget.
  expect(plan.requestWidth % sizeStep, 0);
  expect(plan.requestHeight % sizeStep, 0);
  expect(plan.requestWidth * plan.requestHeight, lessThanOrEqualTo(cap));
  expect(plan.requestWidth, lessThanOrEqualTo(maxRequestSide));
  expect(plan.requestHeight, lessThanOrEqualTo(maxRequestSide));
  // Content sits on the latent grid and fits its canvas.
  expect(plan.contentWidth % latentGrid, 0);
  expect(plan.contentHeight % latentGrid, 0);
  expect(plan.contentOffsetX % latentGrid, 0);
  expect(plan.contentOffsetY % latentGrid, 0);
  expect(plan.contentOffsetX + plan.contentWidth,
      lessThanOrEqualTo(plan.requestWidth));
  expect(plan.contentOffsetY + plan.contentHeight,
      lessThanOrEqualTo(plan.requestHeight));
  // The outer frame stays inside the source image.
  expect(plan.outer.x, greaterThanOrEqualTo(0));
  expect(plan.outer.y, greaterThanOrEqualTo(0));
  expect(plan.outer.right, lessThanOrEqualTo(imageWidth));
  expect(plan.outer.bottom, lessThanOrEqualTo(imageHeight));
  // Context margin is on the 8-px grid and never exceeds the official max.
  // It can be 0 when the region touches an image edge, or when a split tile
  // is large enough that a margin no longer fits the budget.
  expect(plan.contextPx % latentGrid, 0);
  expect(plan.contextPx, inInclusiveRange(0, maxContextPx));
}

void main() {
  test('mask cell grid quantizes to ceil(size / 8) cells', () {
    final cells = gridWithMaskRect(
      imageWidth: 100,
      imageHeight: 60,
      maskRect: const Rectangle(9, 17, 2, 2),
    );
    expect(cells.width, 13);
    expect(cells.height, 8);
    expect(cells.cellAt(1, 2), isTrue);
    expect(cells.cellAt(0, 0), isFalse);
    expect(cells.isEmpty, isFalse);
  });

  test('mask bbox converts cells back to pixel bounds', () {
    final cells = gridWithMaskRect(
      imageWidth: 100,
      imageHeight: 60,
      maskRect: const Rectangle(9, 17, 2, 2),
    );
    final bbox = maskBBoxFromCells(cells, 100, 60)!;
    expect(bbox.x, 8);
    expect(bbox.y, 16);
    expect(bbox.w, 8);
    expect(bbox.h, 8);
  });

  test('area caps follow the NovelAI size tiers', () {
    expect(areaCapForSize(832, 1216), areaCapNormal);
    expect(areaCapForSize(1024, 1024), areaCapNormal);
    expect(areaCapForSize(1024, 1536), areaCapLarge);
    expect(areaCapForSize(1728, 1728), areaCapWallpaper);
  });

  test('automatic focus only applies above the normal free image area', () {
    expect(autocropAppliesToImage(832, 1216), isFalse);
    expect(autocropAppliesToImage(1024, 1024), isFalse);
    expect(autocropAppliesToImage(1025, 1024), isTrue);
    expect(autocropAppliesToImage(1600, 2400), isTrue);
  });

  test('context margin snaps to the 8-px grid within 32..96', () {
    expect(normalizeContextPx(0), 32);
    expect(normalizeContextPx(33), 32);
    expect(normalizeContextPx(64), 64);
    expect(normalizeContextPx(70), 72);
    expect(normalizeContextPx(500), 96);
    expect(defaultContextPx % latentGrid, 0);
  });

  test('a compliant source image is used whole at 1:1', () {
    final cells = gridWithMaskRect(
      imageWidth: 832,
      imageHeight: 1216,
      maskRect: const Rectangle(300, 200, 250, 300),
    );
    final plan = planFocusInpaint(
      imageWidth: 832,
      imageHeight: 1216,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expectValidPlan(plan,
        imageWidth: 832, imageHeight: 1216, cap: areaCapNormal);
    expect(plan.coversWholeImage(832, 1216), isTrue);
    expect(plan.scale, 1.0);
    expect(plan.requestWidth, 832);
    expect(plan.requestHeight, 1216);
    // No padding: the content is the canvas.
    expect(plan.contentOffsetX, 0);
    expect(plan.contentOffsetY, 0);
  });

  test('small mask in a large image gets a large frame at native scale', () {
    final cells = gridWithMaskRect(
      imageWidth: 1600,
      imageHeight: 2400,
      maskRect: const Rectangle(700, 1100, 120, 160),
    );
    final plan = planFocusInpaint(
      imageWidth: 1600,
      imageHeight: 2400,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expectValidPlan(plan,
        imageWidth: 1600, imageHeight: 2400, cap: areaCapNormal);
    // Budget allows a full-size frame, so no magnification is needed.
    expect(plan.scale, 1.0);
    expect(plan.outer.area, greaterThanOrEqualTo(1024 * 1024 - 64 * 64));
    // The mask plus its context margin must fit inside the frame.
    final bbox = maskBBoxFromCells(cells, 1600, 2400)!;
    expect(plan.outer.contains(bbox), isTrue);
    expect(plan.outer.x, lessThanOrEqualTo(bbox.x - plan.contextPx));
    expect(plan.outer.right, greaterThanOrEqualTo(bbox.right + plan.contextPx));
  });

  test('small source image is magnified to use the whole budget', () {
    // 512x512 fits the cap outright, but sending it 1:1 would waste 3/4 of the
    // request canvas. Focus inpainting magnifies instead.
    final cells = gridWithMaskRect(
      imageWidth: 512,
      imageHeight: 512,
      maskRect: const Rectangle(200, 200, 60, 60),
    );
    final plan = planFocusInpaint(
      imageWidth: 512,
      imageHeight: 512,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expectValidPlan(plan,
        imageWidth: 512, imageHeight: 512, cap: areaCapNormal);
    expect(plan.scale, greaterThan(1.0), reason: 'small frame is magnified');
    // The canvas should be close to the budget rather than a tiny 512 request.
    expect(plan.requestWidth * plan.requestHeight,
        greaterThan((areaCapNormal * 0.8).round()));
    expect(plan.requestWidth, greaterThanOrEqualTo(960));
  });

  test('magnified plan keeps the content centred with aligned padding', () {
    final cells = gridWithMaskRect(
      imageWidth: 300,
      imageHeight: 500,
      maskRect: const Rectangle(120, 200, 40, 40),
    );
    final plan = planFocusInpaint(
      imageWidth: 300,
      imageHeight: 500,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expectValidPlan(plan,
        imageWidth: 300, imageHeight: 500, cap: areaCapNormal);
    expect(plan.scale, greaterThan(1.0));
    // Padding is split between both sides, so the offset never exceeds the
    // total slack.
    final slackX = plan.requestWidth - plan.contentWidth;
    final slackY = plan.requestHeight - plan.contentHeight;
    expect(plan.contentOffsetX, lessThanOrEqualTo(slackX));
    expect(plan.contentOffsetY, lessThanOrEqualTo(slackY));
    expect(slackX, lessThan(sizeStep));
    expect(slackY, lessThan(sizeStep));
  });

  test('corner mask still yields a valid in-bounds frame', () {
    final cells = gridWithMaskRect(
      imageWidth: 1600,
      imageHeight: 2400,
      maskRect: const Rectangle(0, 0, 100, 100),
    );
    final plan = planFocusInpaint(
      imageWidth: 1600,
      imageHeight: 2400,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expectValidPlan(plan,
        imageWidth: 1600, imageHeight: 2400, cap: areaCapNormal);
    final bbox = maskBBoxFromCells(cells, 1600, 2400)!;
    expect(plan.outer.contains(bbox), isTrue);
    expect(plan.outer.x, 0);
    expect(plan.outer.y, 0);
  });

  test('mask larger than the budget is refused rather than shrunk', () {
    // Focus inpainting never scales below 1.0, so a mask spanning almost a
    // 2000x3000 image cannot be planned; the caller must fall back.
    final cells = gridWithMaskRect(
      imageWidth: 2000,
      imageHeight: 3000,
      maskRect: const Rectangle(50, 50, 1900, 2900),
    );
    final plan = planFocusInpaint(
      imageWidth: 2000,
      imageHeight: 3000,
      cells: cells,
      maxArea: areaCapNormal,
    );
    expect(plan, isNull);
  });

  test('focused inpainting keeps the same 1 MP cap at larger size tiers', () {
    // A larger general generation size must not make one Focus frame exceed
    // the official 1 MP selection ceiling.
    final cells = gridWithMaskRect(
      imageWidth: 3000,
      imageHeight: 3000,
      maskRect: const Rectangle(400, 600, 1500, 1500),
    );
    expect(
      planFocusInpaint(
        imageWidth: 3000,
        imageHeight: 3000,
        cells: cells,
        maxArea: areaCapNormal,
      ),
      isNull,
    );
    expect(
      planFocusInpaint(
        imageWidth: 3000,
        imageHeight: 3000,
        cells: cells,
        maxArea: areaCapWallpaper,
      ),
      isNull,
    );
  });

  test('a region without room for a margin still gets a frame', () {
    // The mask nearly fills the budget, so no context margin fits; focus
    // inpainting should still plan a frame rather than give up.
    final cells = gridWithMaskRect(
      imageWidth: 3000,
      imageHeight: 3000,
      maskRect: const Rectangle(500, 500, 1010, 1010),
    );
    final plan = planFocusInpaint(
      imageWidth: 3000,
      imageHeight: 3000,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expectValidPlan(plan,
        imageWidth: 3000, imageHeight: 3000, cap: areaCapNormal);
    expect(plan.outer.contains(maskBBoxFromCells(cells, 3000, 3000)!), isTrue);
  });

  test('elongated mask picks a matching frame aspect', () {
    final cells = gridWithMaskRect(
      imageWidth: 1600,
      imageHeight: 2400,
      maskRect: const Rectangle(700, 400, 120, 1200),
    );
    final plan = planFocusInpaint(
      imageWidth: 1600,
      imageHeight: 2400,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expectValidPlan(plan,
        imageWidth: 1600, imageHeight: 2400, cap: areaCapNormal);
    expect(plan.outer.h, greaterThan(plan.outer.w),
        reason: 'a tall mask needs a tall frame');
    final bbox = maskBBoxFromCells(cells, 1600, 2400)!;
    expect(plan.outer.contains(bbox), isTrue);
  });

  test('near-maximum candidates follow mask plus context instead of square',
      () {
    final cells = gridWithMaskRect(
      imageWidth: 1600,
      imageHeight: 2400,
      maskRect: const Rectangle(700, 400, 120, 1200),
    );
    final plan = planFocusInpaint(
      imageWidth: 1600,
      imageHeight: 2400,
      cells: cells,
      maxArea: areaCapNormal,
    )!;

    final bbox = maskBBoxFromCells(cells, 1600, 2400)!;
    final expandedAspect =
        (bbox.w + defaultContextPx * 2) / (bbox.h + defaultContextPx * 2);
    final chosenError =
        (log(plan.outer.w / plan.outer.h) - log(expandedAspect)).abs();
    final squareError = log(expandedAspect).abs();

    expect(plan.outer.h, greaterThan(plan.outer.w));
    expect(chosenError, lessThan(squareError),
        reason: 'the chosen frame follows the expanded mask better than 1:1');
    expect(plan.outer.area, greaterThanOrEqualTo(areaCapNormal * 0.9));
  });

  test('a compact near-square region keeps the stable square frame', () {
    final cells = gridWithMaskRect(
      imageWidth: 1800,
      imageHeight: 1800,
      maskRect: const Rectangle(700, 700, 240, 260),
    );
    final plan = planFocusInpaint(
      imageWidth: 1800,
      imageHeight: 1800,
      cells: cells,
      maxArea: areaCapNormal,
    )!;

    expect(plan.outer.w, plan.outer.h);
    expect(plan.outer.w, 1024);
  });

  test('inner region is the outer frame minus the context margin', () {
    final cells = gridWithMaskRect(
      imageWidth: 1600,
      imageHeight: 2400,
      maskRect: const Rectangle(700, 1100, 120, 160),
    );
    final plan = planFocusInpaint(
      imageWidth: 1600,
      imageHeight: 2400,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expect(plan.inner.x, plan.outer.x + plan.contextPx);
    expect(plan.inner.y, plan.outer.y + plan.contextPx);
    expect(plan.inner.w, plan.outer.w - plan.contextPx * 2);
    expect(plan.inner.h, plan.outer.h - plan.contextPx * 2);
    // The mask must live inside the inner region, not in the context band.
    final bbox = maskBBoxFromCells(cells, 1600, 2400)!;
    expect(plan.inner.contains(bbox), isTrue);
  });

  test('candidate sizes stay 64-aligned and within the area cap', () {
    for (final cap in [areaCapNormal, areaCapLarge, areaCapWallpaper]) {
      final sizes = candidateSizesForArea(cap);
      expect(sizes, isNotEmpty);
      for (final size in sizes) {
        expect(size.x % 64, 0);
        expect(size.y % 64, 0);
        expect(size.x * size.y, lessThanOrEqualTo(cap));
      }
    }
    expect(
      candidateSizesForArea(areaCapNormal),
      contains(const Point(1024, 1024)),
    );
  });

  test('empty mask returns no plan', () {
    final cells = maskCellGridFromPixels(
      imageWidth: 100,
      imageHeight: 100,
      maskPixelAt: (_, __) => false,
    );
    expect(cells.isEmpty, isTrue);
    expect(
      planFocusInpaint(
        imageWidth: 100,
        imageHeight: 100,
        cells: cells,
        maxArea: areaCapNormal,
      ),
      isNull,
    );
  });

  group('split planning', () {
    test('a small mask stays a single tile', () {
      final cells = gridWithMaskRect(
        imageWidth: 1600,
        imageHeight: 2400,
        maskRect: const Rectangle(700, 1100, 120, 160),
      );
      final batch = planFocusInpaintBatch(
        imageWidth: 1600,
        imageHeight: 2400,
        cells: cells,
        maxArea: areaCapNormal,
      )!;
      expect(batch.tileCount, 1);
      expect(batch.isSplit, isFalse);
      expect(batch.splitMode, FocusSplitMode.none);
      expect(batch.serial, isTrue);
    });

    test('a mask filling its frame is halved along the long axis', () {
      // The mask nearly fills the largest frame, so each half gets its own
      // frame and a better effective resolution.
      final cells = gridWithMaskRect(
        imageWidth: 3000,
        imageHeight: 3000,
        maskRect: const Rectangle(900, 900, 1000, 1000),
      );
      final single = planFocusForRegion(
        imageWidth: 3000,
        imageHeight: 3000,
        region: maskBBoxFromCells(cells, 3000, 3000)!,
        maxArea: areaCapNormal,
      )!;
      expect(
        maskedCellRatio(cells, single.outer, 3000, 3000),
        greaterThan(longAxisSplitThreshold),
      );

      final batch = planFocusInpaintBatch(
        imageWidth: 3000,
        imageHeight: 3000,
        cells: cells,
        maxArea: areaCapNormal,
      )!;
      expect(batch.splitMode, FocusSplitMode.longAxis);
      expect(batch.tileCount, 2);
      // The halves get distinct frames, and overlapping frames run serially.
      expect(batch.tiles[0].outer, isNot(batch.tiles[1].outer));
      expect(batch.serial, isTrue);
      for (final tile in batch.tiles) {
        expectValidPlan(tile,
            imageWidth: 3000, imageHeight: 3000, cap: areaCapNormal);
      }
    });

    test('a whole-image-sized mask needs no split', () {
      // On a 1024x1024 source the frame is the image itself, so halving it
      // would gain nothing and both halves collapse back to one frame.
      final cells = gridWithMaskRect(
        imageWidth: 1024,
        imageHeight: 1024,
        maskRect: const Rectangle(20, 20, 984, 984),
      );
      final batch = planFocusInpaintBatch(
        imageWidth: 1024,
        imageHeight: 1024,
        cells: cells,
        maxArea: areaCapNormal,
      )!;
      expect(batch.tileCount, 1);
      expect(batch.splitMode, FocusSplitMode.none);
      expect(batch.tiles.single.coversWholeImage(1024, 1024), isTrue);
    });

    test('a mask too large for one frame becomes a grid', () {
      final cells = gridWithMaskRect(
        imageWidth: 3000,
        imageHeight: 3000,
        maskRect: const Rectangle(100, 100, 2800, 2800),
      );
      final batch = planFocusInpaintBatch(
        imageWidth: 3000,
        imageHeight: 3000,
        cells: cells,
        maxArea: areaCapNormal,
      )!;
      expect(batch.splitMode, FocusSplitMode.grid);
      expect(batch.tileCount, greaterThan(1));
      for (final tile in batch.tiles) {
        expectValidPlan(tile,
            imageWidth: 3000, imageHeight: 3000, cap: areaCapNormal);
      }
      // Every tile frame must be distinct.
      final keys = batch.tiles
          .map((t) => '${t.outer.x},${t.outer.y},${t.outer.w},${t.outer.h}')
          .toSet();
      expect(keys.length, batch.tileCount);
    });

    test('grid tiles together cover the whole mask bounding box', () {
      const imageW = 3000;
      const imageH = 3000;
      final cells = gridWithMaskRect(
        imageWidth: imageW,
        imageHeight: imageH,
        maskRect: const Rectangle(100, 100, 2800, 2800),
      );
      final bbox = maskBBoxFromCells(cells, imageW, imageH)!;
      final batch = planFocusInpaintBatch(
        imageWidth: imageW,
        imageHeight: imageH,
        cells: cells,
        maxArea: areaCapNormal,
      )!;
      // Sample the bbox; every point must fall inside at least one frame.
      for (var y = bbox.y; y < bbox.bottom; y += 97) {
        for (var x = bbox.x; x < bbox.right; x += 97) {
          final covered = batch.tiles.any((tile) =>
              x >= tile.outer.x &&
              x < tile.outer.right &&
              y >= tile.outer.y &&
              y < tile.outer.bottom);
          expect(covered, isTrue, reason: 'point ($x, $y) is not covered');
        }
      }
    });

    test('long-axis split halves the region', () {
      const rect = CropRect(x: 100, y: 200, w: 400, h: 100);
      final halves = splitAlongLongAxis(rect);
      expect(halves.length, 2);
      // Split along the wider axis, boundaries on the latent grid.
      expect(halves[0].y, rect.y);
      expect(halves[0].h, rect.h);
      expect(halves[0].x, rect.x);
      expect(halves[1].right, rect.right);
      expect(halves[0].right, halves[1].x);
      expect(halves[0].right % latentGrid, 0);

      const tall = CropRect(x: 0, y: 0, w: 100, h: 400);
      final tallHalves = splitAlongLongAxis(tall);
      expect(tallHalves.length, 2);
      expect(tallHalves[0].w, tall.w);
      expect(tallHalves[0].bottom, tallHalves[1].y);
    });

    test('tiny regions are not split', () {
      expect(
          splitAlongLongAxis(const CropRect(x: 0, y: 0, w: 8, h: 8)).length, 1);
    });

    test('grid split tiles the region without gaps or overlaps', () {
      const rect = CropRect(x: 0, y: 0, w: 2000, h: 1000);
      final tiles = splitIntoGrid(rect, 700, 700);
      expect(tiles.length, 3 * 2);
      var area = 0;
      for (final tile in tiles) {
        area += tile.area;
        expect(tile.x, greaterThanOrEqualTo(rect.x));
        expect(tile.right, lessThanOrEqualTo(rect.right));
      }
      expect(area, rect.area, reason: 'tiles must exactly cover the region');
    });

    test('masked cell ratio reflects how full the frame is', () {
      final cells = gridWithMaskRect(
        imageWidth: 1024,
        imageHeight: 1024,
        maskRect: const Rectangle(0, 0, 512, 1024),
      );
      final ratio = maskedCellRatio(
        cells,
        const CropRect(x: 0, y: 0, w: 1024, h: 1024),
        1024,
        1024,
      );
      expect(ratio, closeTo(0.5, 0.02));
    });

    test('empty mask yields no batch', () {
      final cells = maskCellGridFromPixels(
        imageWidth: 100,
        imageHeight: 100,
        maskPixelAt: (_, __) => false,
      );
      expect(
        planFocusInpaintBatch(
          imageWidth: 100,
          imageHeight: 100,
          cells: cells,
          maxArea: areaCapNormal,
        ),
        isNull,
      );
    });
  });

  test('whole-image fallback helpers keep their contract', () {
    expect(wholeImageFitsDirect(832, 1216, areaCapNormal), isTrue);
    expect(wholeImageFitsDirect(833, 1216, areaCapNormal), isFalse);
    expect(wholeImageFitsDirect(2048, 2048, areaCapNormal), isFalse);
    final size = requestSizeForWindow(2000, 3000, areaCapNormal);
    expect(size.x % 64, 0);
    expect(size.y % 64, 0);
    expect(size.x * size.y, lessThanOrEqualTo(areaCapNormal));
  });

  group('planManualFocusInpaint', () {
    test('manual focus keeps a visible non-repainted context band', () {
      final cells = gridWithMaskRect(
        imageWidth: 2000,
        imageHeight: 2000,
        maskRect: const Rectangle(700, 700, 100, 100),
      );
      final plan = planManualFocusInpaint(
        imageWidth: 2000,
        imageHeight: 2000,
        cells: cells,
        frame: const CropRect(x: 512, y: 512, w: 512, h: 512),
        maxArea: areaCapNormal,
        contextPx: 80,
      )!;

      expect(plan.contextPx, 80);
      expect(plan.inner, const CropRect(x: 592, y: 592, w: 352, h: 352));
      expect(
          plan.inner.contains(maskBBoxFromCells(cells, 2000, 2000)!), isTrue);
    });

    test('a mask entirely inside the context band is not repainted', () {
      final cells = gridWithMaskRect(
        imageWidth: 2000,
        imageHeight: 2000,
        maskRect: const Rectangle(520, 520, 40, 40),
      );
      final plan = planManualFocusInpaint(
        imageWidth: 2000,
        imageHeight: 2000,
        cells: cells,
        frame: const CropRect(x: 512, y: 512, w: 512, h: 512),
        maxArea: areaCapNormal,
        contextPx: 64,
      );

      expect(plan, isNull);
    });

    test('a small frame is enlarged to fill the budget, like Autocrop', () {
      final cells = gridWithMaskRect(
        imageWidth: 2000,
        imageHeight: 2000,
        maskRect: const Rectangle(600, 600, 100, 100),
      );
      final plan = planManualFocusInpaint(
        imageWidth: 2000,
        imageHeight: 2000,
        cells: cells,
        frame: const CropRect(x: 512, y: 512, w: 512, h: 512),
        maxArea: areaCapNormal,
      );
      expect(plan, isNotNull);
      expect(plan!.outer, const CropRect(x: 512, y: 512, w: 512, h: 512));
      expect(plan.scale, 2.0);
      expect(plan.requestWidth, 1024);
      expect(plan.requestHeight, 1024);
    });

    test('an oversized manual frame is capped at the 1 MP ceiling', () {
      final cells = gridWithMaskRect(
        imageWidth: 2400,
        imageHeight: 2400,
        maskRect: const Rectangle(1000, 1000, 200, 200),
      );
      final plan = planManualFocusInpaint(
        imageWidth: 2400,
        imageHeight: 2400,
        cells: cells,
        frame: const CropRect(x: 200, y: 200, w: 2048, h: 2048),
        maxArea: areaCapNormal,
      );
      expect(plan, isNotNull);
      expect(plan!.outer.area, lessThanOrEqualTo(areaCapNormal));
      expect(plan.outer.w, plan.outer.h);
      expect(plan.requestWidth * plan.requestHeight,
          lessThanOrEqualTo(areaCapNormal));
    });

    test('the frame is snapped to the latent grid and clipped to the image',
        () {
      final cells = gridWithMaskRect(
        imageWidth: 1000,
        imageHeight: 1000,
        maskRect: const Rectangle(100, 100, 200, 200),
      );
      final plan = planManualFocusInpaint(
        imageWidth: 1000,
        imageHeight: 1000,
        cells: cells,
        frame: const CropRect(x: 93, y: 91, w: 333, h: 333),
        maxArea: areaCapNormal,
      );
      expect(plan, isNotNull);
      expect(plan!.outer.x % latentGrid, 0);
      expect(plan.outer.y % latentGrid, 0);
      expect(plan.outer.w % latentGrid, 0);
      expect(plan.outer.h % latentGrid, 0);
      expect(plan.outer.x, greaterThanOrEqualTo(0));
      expect(plan.outer.right, lessThanOrEqualTo(1000));
    });

    test('a frame that misses the mask entirely is rejected', () {
      final cells = gridWithMaskRect(
        imageWidth: 1000,
        imageHeight: 1000,
        maskRect: const Rectangle(700, 700, 100, 100),
      );
      final plan = planManualFocusInpaint(
        imageWidth: 1000,
        imageHeight: 1000,
        cells: cells,
        frame: const CropRect(x: 0, y: 0, w: 256, h: 256),
        maxArea: areaCapNormal,
      );
      expect(plan, isNull);
    });

    test('a degenerate frame is rejected', () {
      final cells = gridWithMaskRect(
        imageWidth: 1000,
        imageHeight: 1000,
        maskRect: const Rectangle(100, 100, 100, 100),
      );
      final plan = planManualFocusInpaint(
        imageWidth: 1000,
        imageHeight: 1000,
        cells: cells,
        frame: const CropRect(x: 100, y: 100, w: 0, h: 0),
        maxArea: areaCapNormal,
      );
      expect(plan, isNull);
    });
  });
}
