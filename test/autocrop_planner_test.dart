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

void main() {
  test('mask cell grid quantizes to ceil(size / 8) cells', () {
    final cells = gridWithMaskRect(
      imageWidth: 100,
      imageHeight: 60,
      maskRect: const Rectangle(9, 17, 2, 2),
    );
    expect(cells.width, 13);
    expect(cells.height, 8);
    // Pixels (9..10, 17..18) live in cells (1, 2).
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
    // Cell (1, 2) covers pixels 8..15 x 16..23.
    expect(bbox.x, 8);
    expect(bbox.y, 16);
    expect(bbox.w, 8);
    expect(bbox.h, 8);
  });

  test('area caps follow the NovelAI size tiers', () {
    expect(areaCapForSize(832, 1216), areaCapNormal);
    expect(areaCapForSize(1024, 1024), areaCapNormal);
    expect(areaCapForSize(1024, 1536), areaCapLarge);
    expect(areaCapForSize(1472, 1472), areaCapLarge);
    expect(areaCapForSize(1728, 1728), areaCapWallpaper);
  });

  test('candidate sizes stay 64-aligned and within the area cap', () {
    for (final cap in [areaCapNormal, areaCapLarge, areaCapWallpaper]) {
      final sizes = candidateSizesForArea(cap);
      expect(sizes, isNotEmpty);
      for (final size in sizes) {
        expect(size.x % 64, 0, reason: 'width 64-aligned for cap $cap');
        expect(size.y % 64, 0, reason: 'height 64-aligned for cap $cap');
        expect(size.x * size.y, lessThanOrEqualTo(cap));
        expect(size.x, inInclusiveRange(64, maxRequestSide));
        expect(size.y, inInclusiveRange(64, maxRequestSide));
      }
    }
    expect(
      candidateSizesForArea(areaCapNormal),
      contains(const Point(1024, 1024)),
    );
    expect(
      candidateSizesForArea(areaCapNormal),
      contains(const Point(832, 1216)),
    );
  });

  test('compliant whole image goes direct', () {
    final cells = gridWithMaskRect(
      imageWidth: 832,
      imageHeight: 1216,
      maskRect: const Rectangle(100, 100, 50, 50),
    );
    final plan = planAutocrop(
      imageWidth: 832,
      imageHeight: 1216,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expect(plan.wholeImageDirect, isTrue);
    expect(plan.scaled, isFalse);
    expect(plan.requestWidth, 832);
    expect(plan.requestHeight, 1216);
    expect(plan.window, const CropRect(x: 0, y: 0, w: 832, h: 1216));
  });

  test('small mask in a large image gets a native max window', () {
    final cells = gridWithMaskRect(
      imageWidth: 1600,
      imageHeight: 2400,
      maskRect: const Rectangle(700, 1100, 120, 160),
    );
    final plan = planAutocrop(
      imageWidth: 1600,
      imageHeight: 2400,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expect(plan.wholeImageDirect, isFalse);
    expect(plan.scaled, isFalse);
    // Native window: request size equals window size, 64-aligned, at cap.
    expect(plan.requestWidth, plan.window.w);
    expect(plan.requestHeight, plan.window.h);
    expect(plan.requestWidth % 64, 0);
    expect(plan.requestHeight % 64, 0);
    expect(
      plan.requestWidth * plan.requestHeight,
      lessThanOrEqualTo(areaCapNormal),
    );
    // The window is the biggest candidate (area == 1024x1024 tier best).
    expect(plan.window.area, greaterThanOrEqualTo(1024 * 1024 - 64 * 64));
    // Mask bbox must be fully inside the window.
    expect(plan.window.contains(plan.maskBBox), isTrue);
    // Window stays within the padded image bounds.
    expect(plan.window.x, greaterThanOrEqualTo(-windowOverhang));
    expect(plan.window.y, greaterThanOrEqualTo(-windowOverhang));
    expect(plan.window.right, lessThanOrEqualTo(1600 + windowOverhang));
    expect(plan.window.bottom, lessThanOrEqualTo(2400 + windowOverhang));
  });

  test('corner mask window clamps to the padded image bounds', () {
    final cells = gridWithMaskRect(
      imageWidth: 1600,
      imageHeight: 2400,
      maskRect: const Rectangle(0, 0, 100, 100),
    );
    final plan = planAutocrop(
      imageWidth: 1600,
      imageHeight: 2400,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expect(plan.wholeImageDirect, isFalse);
    expect(plan.scaled, isFalse);
    expect(plan.window.contains(plan.maskBBox), isTrue);
    expect(plan.window.x, greaterThanOrEqualTo(-windowOverhang));
    expect(plan.window.y, greaterThanOrEqualTo(-windowOverhang));
  });

  test('oversized mask falls back to a scaled window', () {
    final cells = gridWithMaskRect(
      imageWidth: 2000,
      imageHeight: 3000,
      maskRect: const Rectangle(50, 50, 1900, 2900),
    );
    final plan = planAutocrop(
      imageWidth: 2000,
      imageHeight: 3000,
      cells: cells,
      maxArea: areaCapNormal,
    )!;
    expect(plan.wholeImageDirect, isFalse);
    expect(plan.scaled, isTrue);
    expect(plan.requestWidth % 64, 0);
    expect(plan.requestHeight % 64, 0);
    expect(
      plan.requestWidth * plan.requestHeight,
      lessThanOrEqualTo(areaCapNormal),
    );
    // The scaled window must still cover the whole mask.
    expect(plan.window.contains(plan.maskBBox), isTrue);
    // Window stays inside the actual image on the fallback path.
    expect(plan.window.x, greaterThanOrEqualTo(0));
    expect(plan.window.y, greaterThanOrEqualTo(0));
    expect(plan.window.right, lessThanOrEqualTo(2000));
    expect(plan.window.bottom, lessThanOrEqualTo(3000));
  });

  test('request size scaling keeps aspect and respects bounds', () {
    final size = requestSizeForWindow(2000, 3000, areaCapNormal);
    expect(size.x % 64, 0);
    expect(size.y % 64, 0);
    expect(size.x * size.y, lessThanOrEqualTo(areaCapNormal));
    const aspectIn = 2000 / 3000;
    final aspectOut = size.x / size.y;
    expect((aspectIn - aspectOut).abs(), lessThan(0.15));
  });

  test('empty mask returns no plan', () {
    final cells = maskCellGridFromPixels(
      imageWidth: 100,
      imageHeight: 100,
      maskPixelAt: (_, __) => false,
    );
    expect(cells.isEmpty, isTrue);
    expect(
      planAutocrop(
        imageWidth: 100,
        imageHeight: 100,
        cells: cells,
        maxArea: areaCapNormal,
      ),
      isNull,
    );
  });
}
