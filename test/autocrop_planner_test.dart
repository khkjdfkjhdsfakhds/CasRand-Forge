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
  // Context margin is on the 8-px grid within the official range.
  expect(plan.contextPx % latentGrid, 0);
  expect(plan.contextPx, inInclusiveRange(minContextPx, maxContextPx));
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
    expectValidPlan(plan, imageWidth: 512, imageHeight: 512, cap: areaCapNormal);
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
    expectValidPlan(plan, imageWidth: 300, imageHeight: 500, cap: areaCapNormal);
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

  test('a wider budget admits a frame the normal cap refuses', () {
    final cells = gridWithMaskRect(
      imageWidth: 2000,
      imageHeight: 3000,
      maskRect: const Rectangle(400, 600, 1000, 1000),
    );
    expect(
      planFocusInpaint(
        imageWidth: 2000,
        imageHeight: 3000,
        cells: cells,
        maxArea: areaCapNormal,
      ),
      isNull,
    );
    final plan = planFocusInpaint(
      imageWidth: 2000,
      imageHeight: 3000,
      cells: cells,
      maxArea: areaCapWallpaper,
    )!;
    expectValidPlan(plan,
        imageWidth: 2000, imageHeight: 3000, cap: areaCapWallpaper);
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

  test('whole-image fallback helpers keep their contract', () {
    expect(wholeImageFitsDirect(832, 1216, areaCapNormal), isTrue);
    expect(wholeImageFitsDirect(833, 1216, areaCapNormal), isFalse);
    expect(wholeImageFitsDirect(2048, 2048, areaCapNormal), isFalse);
    final size = requestSizeForWindow(2000, 3000, areaCapNormal);
    expect(size.x % 64, 0);
    expect(size.y % 64, 0);
    expect(size.x * size.y, lessThanOrEqualTo(areaCapNormal));
  });
}
